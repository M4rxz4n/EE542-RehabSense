#!/usr/bin/env python3
"""Structural cross-check of the Dart sources, without a Dart SDK.

Why this exists
---------------
`flutter analyze` is the real answer and nothing here replaces it. But this
project's code was written in an environment with no Dart toolchain, and
shipping several thousand lines of unchecked Dart across twenty files is how
you end up with a typo in a colour constant that nobody sees until a demo.

So this checks the things that go wrong *across* files, which is where the
mistakes actually are:

  1. delimiters balance, per file
  2. every relative import resolves to a file that exists
  3. no two files declare the same top-level name (an import collision waiting
     to happen)
  4. every capitalised identifier a file uses is declared in that file, in
     something it imports, or in a known SDK name
  5. every `Type.member` access on a type this project declares names a member
     that type actually has
  6. every named argument in a call to one of this project's constructors is a
     parameter that constructor accepts

What it does NOT do: type checking, null-safety, control flow, generics,
overload resolution. A clean run here means "the names line up", not "it
compiles".

Usage:  python3 tool/check_dart.py [lib_dir]
Exit:   0 clean, 1 findings.
"""

from __future__ import annotations

import os
import re
import sys
from collections import defaultdict

# ── Lexing: strip what must not be parsed ──────────────────────────────────


def strip_noise(src: str) -> str:
    """Replace comments and string bodies with spaces, keeping offsets.

    Keeping length identical means a line number from the stripped text still
    points at the right line in the original, which is the whole point of
    doing it this way rather than deleting.
    """
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        # Line comment
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
            continue
        # Block comment, nesting as Dart allows
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            depth = 0
            while i < n:
                if src[i] == "/" and i + 1 < n and src[i + 1] == "*":
                    depth += 1
                    out[i] = out[i + 1] = " "
                    i += 2
                    continue
                if src[i] == "*" and i + 1 < n and src[i + 1] == "/":
                    depth -= 1
                    out[i] = out[i + 1] = " "
                    i += 2
                    if depth == 0:
                        break
                    continue
                if src[i] != "\n":
                    out[i] = " "
                i += 1
            continue
        # Strings. Raw and triple quoted both matter here.
        if c in "\"'" or (c == "r" and i + 1 < n and src[i + 1] in "\"'"):
            raw = c == "r"
            if raw:
                out[i] = " "
                i += 1
                c = src[i]
            quote = c
            triple = src[i : i + 3] == quote * 3
            delim = quote * 3 if triple else quote
            out[i : i + len(delim)] = " " * len(delim)
            i += len(delim)
            while i < n:
                if not raw and src[i] == "\\":
                    out[i] = " "
                    if i + 1 < n and src[i + 1] != "\n":
                        out[i + 1] = " "
                    i += 2
                    continue
                if src[i : i + len(delim)] == delim:
                    out[i : i + len(delim)] = " " * len(delim)
                    i += len(delim)
                    break
                # An interpolation is real code and must survive, or every
                # identifier used only inside one looks undeclared.
                #
                # It is stripped RECURSIVELY, because an interpolation may
                # itself hold string literals — `'${a ? 'yes' : 'no'}'` is
                # ordinary Dart. Copying the braces verbatim leaks those inner
                # literals into the code stream, and every capitalised word
                # inside one then reports as an undeclared identifier. That
                # produced a crop of phantom findings before it was caught.
                if not raw and src[i] == "$":
                    i += 1
                    if i < n and src[i] == "{":
                        start = i
                        depth = 0
                        while i < n:
                            if src[i] == "{":
                                depth += 1
                            elif src[i] == "}":
                                depth -= 1
                                if depth == 0:
                                    i += 1
                                    break
                            i += 1
                        inner = strip_noise(src[start:i])
                        out[start:i] = list(inner)
                    else:
                        while i < n and (src[i].isalnum() or src[i] in "_."):
                            i += 1
                    continue
                if src[i] != "\n":
                    out[i] = " "
                i += 1
            continue
        i += 1
    return "".join(out)


# ── Declarations ──────────────────────────────────────────────────────────

TYPE_DECL = re.compile(
    r"^\s*(?:abstract\s+|final\s+|base\s+|interface\s+|sealed\s+|mixin\s+)*"
    r"(class|enum|mixin|extension|typedef)\s+([A-Z_$][A-Za-z0-9_$]*)",
    re.M,
)

TOP_FUNC = re.compile(
    r"^(?:[A-Za-z_$][\w<>,\s\[\]?$.]*?\s+)?([a-z_$][A-Za-z0-9_$]*)\s*"
    r"(?:<[^>()]*>)?\([^;{]*?\)\s*(?:async\s*\*?\s*|sync\s*\*\s*)?[{=]",
    re.M,
)

TOP_VAR = re.compile(
    r"^(?:const|final|late\s+final|late|var)\s+(?:[A-Za-z_$][\w<>,\s?$.]*\s+)?"
    r"([a-z_$][A-Za-z0-9_$]*)\s*[=;]",
    re.M,
)

MEMBER = re.compile(
    r"^\s{2,}(?:@\w+\s+)*"
    r"(?:static\s+|const\s+|final\s+|late\s+|var\s+|external\s+|covariant\s+)*"
    r"(?:[A-Za-z_$][\w<>,\s\[\]?$.]*?\s+)?"
    r"(?:get\s+|set\s+|operator\s+)?"
    r"([A-Za-z_$][A-Za-z0-9_$]*)\s*(?:<[^>()]*>)?\s*[({=;]",
    re.M,
)

ENUM_CONST = re.compile(r"^\s{2,}([a-z_$][A-Za-z0-9_$]*)\s*(?:\(|,|;|$)", re.M)

IMPORT = re.compile(r"""^\s*(?:import|export)\s+['"]([^'"]+)['"]""", re.M)


def block_of(text: str, start: int) -> str:
    """The brace-delimited body beginning at or after `start`."""
    i = text.find("{", start)
    if i < 0:
        return ""
    depth, j = 0, i
    while j < len(text):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i : j + 1]
        j += 1
    return text[i:]


def strip_comments_only(src: str) -> str:
    """Comments gone, string bodies intact — so import paths survive."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        if src[i] == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
            continue
        if src[i] == "/" and i + 1 < n and src[i + 1] == "*":
            while i < n and not (src[i] == "*" and i + 1 < n and src[i + 1] == "/"):
                if src[i] != "\n":
                    out[i] = " "
                i += 1
            if i < n:
                out[i] = out[i + 1] = " "
                i += 2
            continue
        # Skip over a string so a '//' inside one is not taken for a comment.
        if src[i] in "\"'":
            q = src[i]
            i += 1
            while i < n and src[i] != q:
                i += 2 if src[i] == "\\" else 1
            i += 1
            continue
        i += 1
    return "".join(out)


class FileInfo:
    def __init__(self, path: str, src: str):
        self.path = path
        self.raw = src
        self.code = strip_noise(src)
        # Imports are read with strings intact: strip_noise blanks the path.
        self.imports: list[str] = IMPORT.findall(strip_comments_only(src))
        self.types: dict[str, dict] = {}
        self.top_names: set[str] = set()
        self._collect()

    def _collect(self) -> None:
        for m in TYPE_DECL.finditer(self.code):
            kind, name = m.group(1), m.group(2)
            body = block_of(self.code, m.end()) if kind != "typedef" else ""
            members = set(MEMBER.findall(body))
            if kind == "enum":
                # Enum constants come before the first ';' in the body.
                head = body.split(";", 1)[0]
                members |= set(ENUM_CONST.findall(head))
                members |= {"values", "name", "index"}
            # Named and factory constructors are members of the type's name
            # space too: `CalibRecord.empty()` is reached as a member.
            for cm in re.finditer(
                rf"\b(?:factory\s+|const\s+)*{re.escape(name)}\s*\.\s*"
                r"([A-Za-z_$][A-Za-z0-9_$]*)",
                body,
            ):
                members.add(cm.group(1))
            # And static members declared with an explicit type on one line.
            for sm in re.finditer(
                r"\bstatic\s+(?:const\s+|final\s+|late\s+)*"
                r"(?:[A-Za-z_$][\w<>,\s?$.]*\s+)?([A-Za-z_$][A-Za-z0-9_$]*)",
                body,
            ):
                members.add(sm.group(1))
            members |= {"new", "toString", "hashCode", "runtimeType", "noSuchMethod"}
            # A constructor's named parameters, for check 6.
            params = set()
            for cm in re.finditer(
                rf"\b(?:const\s+)?{re.escape(name)}(?:\.[A-Za-z0-9_$]+)?\s*\(",
                body,
            ):
                params |= named_params(body, cm.end() - 1)
            self.types[name] = {"kind": kind, "members": members, "params": params}
            self.top_names.add(name)

        # Top-level functions and variables live outside any brace.
        for m in TOP_FUNC.finditer(self.code):
            self.top_names.add(m.group(1))
        for m in TOP_VAR.finditer(self.code):
            self.top_names.add(m.group(1))


def named_params(text: str, open_paren: int) -> set[str]:
    """Named parameters declared in the `{...}` of a parameter list."""
    depth, i = 0, open_paren
    while i < len(text):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                break
        i += 1
    sig = text[open_paren : i + 1]
    brace = sig.find("{")
    if brace < 0:
        return set()
    inner = sig[brace + 1 : sig.rfind("}")] if "}" in sig else sig[brace + 1 :]
    out = set()
    for part in split_top(inner):
        part = part.strip().rstrip(",")
        if not part:
            continue
        part = part.split("=")[0].strip()
        tok = re.findall(r"[A-Za-z_$][A-Za-z0-9_$]*", part)
        if tok:
            out.add(tok[-1])
    return out


def split_top(s: str) -> list[str]:
    """Split on commas not nested inside brackets.

    Angle brackets are deliberately NOT counted. `=>` is far commoner in an
    argument list than a generic is, and counting its '>' drives the depth
    negative, after which every comma looks top level and arguments get split
    in the middle. That produced a crop of phantom "unknown named parameter"
    findings before it was caught.
    """
    out, depth, cur = [], 0, []
    for ch in s:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return out


# ── Known SDK and package names ───────────────────────────────────────────
#
# Not exhaustive and not meant to be: anything missing shows up as a finding,
# and adding it here is a one-line fix. That is the right trade — a name this
# file has never heard of is exactly what a reviewer should look at.

SDK = set(
    """
Object String int double num bool List Map Set Iterable Future Stream Duration
DateTime Function Comparable Exception Error StateError ArgumentError
FormatException RangeError UnsupportedError UnimplementedError Type Symbol
Record Enum Null Never dynamic void Uri Random Queue LinkedHashMap HashMap
SplayTreeMap StringBuffer RegExp RegExpMatch Match Pattern Completer Timer
Zone StreamController StreamSubscription StreamTransformer Sink EventSink
Uint8List Uint16List Uint32List Int8List Int16List Int32List Int64List
Float32List Float64List ByteData ByteBuffer Endian TypedData
File Directory FileSystemEntity FileMode Platform Process HttpServer
HttpRequest HttpResponse HttpHeaders HttpStatus WebSocket
WebSocketTransformer ContentType InternetAddress NetworkInterface Socket
ServerSocket SocketException IOException
JsonEncoder JsonDecoder Utf8Encoder Utf8Decoder Encoding LineSplitter
Comparator Iterator MapEntry Expando Finalizer WeakReference BigInt
StackTrace Stopwatch
Widget StatelessWidget StatefulWidget State InheritedWidget Key GlobalKey
ValueKey ObjectKey UniqueKey BuildContext Element RenderObject
MaterialApp Scaffold AppBar Text TextStyle TextSpan TextPainter TextAlign
TextDirection TextBaseline TextOverflow TextEditingController TextField
TextInputType TextInputAction InputDecoration FontWeight FontStyle
FontFeature Color Colors ColorScheme ThemeData Theme Brightness
Container Padding Center Align Column Row Stack Positioned Expanded Flexible
SizedBox Spacer Wrap Flex MainAxisAlignment CrossAxisAlignment MainAxisSize
WrapAlignment Axis Alignment AlignmentGeometry EdgeInsets EdgeInsetsGeometry
BoxDecoration BoxConstraints BoxShape BoxFit BoxShadow Border BorderSide
BorderRadius BorderRadiusGeometry RoundedRectangleBorder StadiumBorder
CircleBorder OutlinedBorder ShapeBorder Radius Rect Offset Size RRect
Path PathFillType Paint PaintingStyle StrokeCap StrokeJoin MaskFilter
BlurStyle Canvas CustomPaint CustomPainter CustomClipper ClipRRect ClipRect
ClipPath ClipOval Transform Matrix4 Gradient LinearGradient RadialGradient
SweepGradient TileMode Shader ImageFilter BackdropFilter Opacity
Icon Icons IconData IconButton Image AssetImage NetworkImage
ElevatedButton TextButton OutlinedButton FilledButton IconButtonTheme
FilledButtonThemeData OutlinedButtonThemeData TextButtonThemeData
ElevatedButtonThemeData ButtonStyle MaterialStateProperty WidgetStateProperty
InkWell GestureDetector Listener MouseRegion Draggable DragTarget
ListView GridView SingleChildScrollView Scrollable ScrollController
ScrollPhysics NeverScrollableScrollPhysics ClampingScrollPhysics
BouncingScrollPhysics ScrollNotification NotificationListener
CustomScrollView SliverList SliverGrid SliverToBoxAdapter SliverAppBar
SliverChildBuilderDelegate SliverChildListDelegate
PageView PageController TabBar TabBarView TabController DefaultTabController
Tab NavigationBar NavigationDestination BottomNavigationBar
BottomNavigationBarItem NavigationRail NavigationRailDestination
Drawer ListTile CheckboxListTile SwitchListTile RadioListTile Divider
VerticalDivider Card Chip ActionChip FilterChip InputChip CircleAvatar
Tooltip Banner MaterialBanner SnackBar SnackBarAction SnackBarBehavior
SnackBarThemeData ScaffoldMessenger AlertDialog SimpleDialog Dialog
showDialog showModalBottomSheet BottomSheet PopupMenuButton PopupMenuItem
DropdownButton DropdownMenuItem DropdownButtonFormField Slider RangeSlider
SliderTheme SliderThemeData Switch Checkbox Radio
Chip ChoiceChip FilterChip ActionChip InputChip ChipTheme ChipThemeData
SegmentedButton ButtonSegment ToggleButtons
CircularProgressIndicator LinearProgressIndicator RefreshIndicator
AnimatedBuilder AnimatedContainer AnimatedOpacity AnimatedPositioned
AnimatedSwitcher AnimatedDefaultTextStyle AnimatedCrossFade
AnimationController Animation Tween CurvedAnimation Curve Curves
TickerProvider SingleTickerProviderStateMixin TickerProviderStateMixin
Ticker FadeTransition SlideTransition ScaleTransition RotationTransition
ValueNotifier ValueListenable ChangeNotifier Listenable ListenableBuilder
ValueListenableBuilder AnimatedWidget StreamBuilder FutureBuilder
Builder LayoutBuilder OrientationBuilder MediaQuery MediaQueryData
Orientation Navigator Route MaterialPageRoute PageRoute ModalRoute
RouteSettings WidgetsApp WidgetsBinding WidgetsFlutterBinding
SchedulerBinding Clipboard ClipboardData HapticFeedback SystemSound
SystemChrome SystemUiOverlayStyle DeviceOrientation
Focus FocusNode FocusScope SafeArea Hero Material MaterialType
Semantics ExcludeSemantics MergeSemantics RepaintBoundary
VoidCallback ValueChanged ValueGetter ValueSetter WidgetBuilder
IndexedWidgetBuilder TransitionBuilder AsyncSnapshot ConnectionState
DiagnosticsNode DiagnosticPropertiesBuilder
debugPrint kDebugMode kReleaseMode kProfileMode compute
Guid BluetoothDevice BluetoothCharacteristic BluetoothService
BluetoothConnectionState FlutterBluePlus ScanResult AdvertisementData
BluetoothAdapterState DeviceIdentifier
Permission PermissionStatus PermissionWithService
getApplicationDocumentsDirectory getTemporaryDirectory
unawaited jsonEncode jsonDecode utf8 ascii base64 min max pow sqrt sin cos
tan atan atan2 acos asin exp log pi
InternetAddressType TimeoutException HttpClient HttpClientRequest
HttpClientResponse LogLevel OutlineInputBorder UnderlineInputBorder
InputBorder SelectableText FractionallySizedBox RangeValues AppBarTheme
IconThemeData TextTheme TextThemeData DividerThemeData ListTileThemeData
ChipThemeData DialogTheme TabBarTheme NavigationBarThemeData
ScrollbarThemeData ProgressIndicatorThemeData SliderComponentShape
VisualDensity MaterialTapTargetSize PageStorageKey AutomaticKeepAlive
FittedBox IntrinsicHeight IntrinsicWidth AspectRatio ConstrainedBox
DecoratedBox Baseline OverflowBox UnconstrainedBox LimitedBox
Table TableRow TableCell TableBorder TableColumnWidth FlexColumnWidth
FixedColumnWidth IntrinsicColumnWidth DataTable DataColumn DataRow DataCell
ReorderableListView Dismissible SliverFillRemaining ScrollbarPainter
Scrollbar RawScrollbar ScrollMetrics ScrollPosition
Ink InkResponse Splash InkSparkle
TextScaler StrutStyle TextHeightBehavior PlaceholderAlignment
LinearBorder BeveledRectangleBorder ContinuousRectangleBorder
NumberFormat DateFormat
IgnorePointer HitTestBehavior AbsorbPointer PointerEvent PointerDownEvent
DragUpdateDetails DragStartDetails DragEndDetails TapDownDetails TapUpDetails
LongPressStartDetails LongPressMoveUpdateDetails LongPressEndDetails
ScaleStartDetails ScaleUpdateDetails ScaleEndDetails
PreferredSizeWidget PreferredSize Size Rect Radius
""".split()
)

ALLOW_PREFIX = ("_",)


def package_name(start: str) -> str | None:
    """This package's own name, so `package:self/x.dart` resolves to lib/x.dart.

    Without it every test file — which imports its own library by package
    URI, as a test must — reports every type it uses as undeclared.
    """
    d = os.path.abspath(start)
    for _ in range(4):
        p = os.path.join(d, "pubspec.yaml")
        if os.path.isfile(p):
            with open(p, encoding="utf-8") as fh:
                for line in fh:
                    m = re.match(r"^name:\s*(\S+)", line)
                    if m:
                        return m.group(1)
        d = os.path.dirname(d)
    return None


def main(*roots: str) -> int:
    files: dict[str, FileInfo] = {}
    for root_dir in roots:
        for root, _dirs, names in os.walk(root_dir):
            for n in sorted(names):
                if n.endswith(".dart"):
                    p = os.path.join(root, n)
                    with open(p, encoding="utf-8") as fh:
                        files[os.path.abspath(p)] = FileInfo(p, fh.read())

    pkg = package_name(roots[0] if roots else ".")
    lib_root = None
    if pkg:
        d = os.path.abspath(roots[0] if roots else ".")
        for _ in range(4):
            cand = os.path.join(d, "lib")
            if os.path.isdir(cand):
                lib_root = cand
                break
            d = os.path.dirname(d)

    def resolve(path: str, imp: str) -> str | None:
        """An import target's absolute path, or None if it is external."""
        if imp.startswith("dart:"):
            return None
        if imp.startswith("package:"):
            if pkg is None or lib_root is None:
                return None
            prefix = f"package:{pkg}/"
            if not imp.startswith(prefix):
                return None  # a real third-party package
            return os.path.abspath(os.path.join(lib_root, imp[len(prefix):]))
        return os.path.abspath(os.path.join(os.path.dirname(path), imp))

    if not files:
        print(f"no .dart files under {lib}")
        return 1

    findings: list[str] = []

    # 1 ── delimiters
    for info in files.values():
        for open_c, close_c in (("(", ")"), ("[", "]"), ("{", "}")):
            a = info.code.count(open_c)
            b = info.code.count(close_c)
            if a != b:
                findings.append(
                    f"{info.path}: {a} '{open_c}' vs {b} '{close_c}' — unbalanced"
                )

    # 2 ── imports resolve
    for path, info in files.items():
        for imp in info.imports:
            target = resolve(path, imp)
            if target is None:
                continue
            if target not in files:
                findings.append(f"{info.path}: import '{imp}' does not resolve")

    # 3 ── duplicate top-level type names
    owners: dict[str, list[str]] = defaultdict(list)
    for info in files.values():
        for t in info.types:
            owners[t].append(info.path)
    for name, where in sorted(owners.items()):
        # A leading underscore makes a type library-private in Dart, so the
        # same private name in two files is legal and common — every screen
        # here has its own _Card. Only public collisions are a problem.
        if len(where) > 1 and not name.startswith("_"):
            findings.append(
                f"type '{name}' declared in {len(where)} files: {', '.join(where)}"
            )

    # Build the visible set per file: its own names plus everything it imports.
    all_types: dict[str, dict] = {}
    for info in files.values():
        for t, d in info.types.items():
            all_types.setdefault(t, d)

    def visible(path: str) -> tuple[set[str], dict[str, dict]]:
        info = files[path]
        names = set(info.top_names)
        types = dict(info.types)
        for imp in info.imports:
            t = resolve(path, imp)
            if t is not None and t in files:
                names |= files[t].top_names
                types.update(files[t].types)
        return names, types

    ident = re.compile(r"\b([A-Z][A-Za-z0-9_$]*)\b")
    member_access = re.compile(r"\b([A-Z][A-Za-z0-9_$]*)\s*\.\s*([A-Za-z_$][A-Za-z0-9_$]*)")

    for path, info in files.items():
        names, types = visible(path)

        # 4 ── capitalised identifiers are declared somewhere reachable
        seen_missing: set[str] = set()
        for m in ident.finditer(info.code):
            name = m.group(1)
            if name in SDK or name in names or name in types:
                continue
            if name.startswith(ALLOW_PREFIX) or name in seen_missing:
                continue
            # A name used only as a label after '.' is a member, handled below.
            before = info.code[max(0, m.start() - 1) : m.start()]
            if before == ".":
                continue
            seen_missing.add(name)
            line = info.code[: m.start()].count("\n") + 1
            findings.append(
                f"{info.path}:{line}: '{name}' is not declared here, imported, "
                f"or a known SDK name"
            )

        # 5 ── Type.member exists on a project type
        for m in member_access.finditer(info.code):
            tname, member = m.group(1), m.group(2)
            d = types.get(tname)
            if d is None:
                continue
            if member in d["members"]:
                continue
            # Constructors and factories share the type's name space.
            if member in ("values", "name", "index", "new"):
                continue
            line = info.code[: m.start()].count("\n") + 1
            findings.append(
                f"{info.path}:{line}: {tname}.{member} — "
                f"'{member}' is not a member of {d['kind']} {tname}"
            )

        # 6 ── named arguments match a project constructor's parameters
        for m in re.finditer(
            r"\b(?:const\s+)?([A-Z][A-Za-z0-9_$]*)\s*\(", info.code
        ):
            tname = m.group(1)
            d = types.get(tname)
            if d is None or d["kind"] not in ("class",) or not d["params"]:
                continue
            depth, i = 0, m.end() - 1
            while i < len(info.code):
                if info.code[i] == "(":
                    depth += 1
                elif info.code[i] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            call = info.code[m.end() : i]
            for arg in split_top(call):
                am = re.match(r"\s*([a-z_$][A-Za-z0-9_$]*)\s*:", arg)
                if not am:
                    continue
                key = am.group(1)
                if key in d["params"] or key in d["members"]:
                    continue
                line = info.code[: m.start()].count("\n") + 1
                findings.append(
                    f"{info.path}:{line}: {tname}(... {key}: ...) — "
                    f"'{key}' is not a named parameter of {tname}"
                )

    print(f"checked {len(files)} files, {len(all_types)} types")
    if not findings:
        print("no structural findings")
        print("\nThis is a name-level check, not a compile. Run "
              "`flutter analyze` and `flutter test` on a machine with the SDK.")
        return 0

    for f in sorted(set(findings)):
        print(f)
    print(f"\n{len(set(findings))} finding(s)")
    return 1


if __name__ == "__main__":
    sys.exit(main(*(sys.argv[1:] or ["lib", "test"])))
