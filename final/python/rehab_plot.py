"""
rehab_plot.py — optional live view.

The recorded log is this tool's more important job; the plot is for the bench,
where watching the angle trace while moving an arm is the fastest way to tell
whether the fusion output is sane and the bands are in the right place.

It reads only from a bounded buffer the session fills, never from the BLE
queue, so a slow redraw cannot stall the link. Everything drawn is what the
device reported — repetition counts, states, compensation and fatigue all
arrive as events and are displayed, not re-derived.
"""

from __future__ import annotations

import asyncio
from collections import deque

import rehab_protocol as p

WINDOW_S = 20.0

_STATE_LABEL = {
    int(p.RepState.READY): "ready",
    int(p.RepState.CONCENTRIC): "concentric",
    int(p.RepState.PEAK): "peak",
    int(p.RepState.ECCENTRIC): "eccentric",
    int(p.RepState.EXTENDED_HOLD): "hold (counts here)",
}


class LiveBuffer:
    """Bounded history the plot reads. Fed from the drain task."""

    def __init__(self, seconds: float = WINDOW_S) -> None:
        n = int(seconds * p.FEATURE_RATE_HZ) + 10
        self.t: deque[float] = deque(maxlen=n)
        self.angle: deque[float] = deque(maxlen=n)
        self.env_a: deque[float] = deque(maxlen=n)
        self.env_b: deque[float] = deque(maxlen=n)
        self.scores: deque[tuple[int, int, int]] = deque(maxlen=60)
        self.mdf: deque[tuple[int, float]] = deque(maxlen=60)
        self.rep_state = 0
        self.rep_count = 0
        self.comp_flags = 0
        self.battery_pct = 100
        self.last_event = ""

    def feature(self, fr: p.FeatureFrame) -> None:
        self.t.append(fr.t_us / 1e6)
        self.angle.append(fr.elbow_angle_deg)
        self.env_a.append(fr.envelope[0] * 100.0)
        self.env_b.append(fr.envelope[1] * 100.0)
        self.rep_state = fr.rep_state
        self.rep_count = fr.rep_count
        self.comp_flags = fr.comp_flags
        if fr.mdf[0] > 0:
            self.mdf.append((fr.rep_count, fr.mdf[0]))

    def rep(self, rc: p.RepComplete) -> None:
        self.scores.append((rc.index, rc.score, rc.comp_flags))

    def event(self, fr: p.EventFrame) -> None:
        self.last_event = fr.name.lower().replace("_", " ")

    def status(self, st: p.StatusFrame) -> None:
        self.battery_pct = st.battery_pct


class LivePlot:
    """Angle against the repetition bands, the two envelopes, and per-rep
    scores. Degrades to nothing if matplotlib is missing or headless."""

    def __init__(self, buf: LiveBuffer, calib: p.CalibRecord,
                 window_s: float = WINDOW_S) -> None:
        self.buf = buf
        self.calib = calib
        self.window_s = window_s
        self.ok = False
        self._fig = None
        try:
            import matplotlib
            if matplotlib.get_backend().lower() in {"agg", "pdf", "ps", "svg",
                                                    "template"}:
                print("  plot: non-interactive backend, live view disabled")
                return
            import matplotlib.pyplot as plt
        except ImportError:
            print("  plot: matplotlib not installed, live view disabled")
            return

        plt.ion()
        fig, axes = plt.subplots(3, 1, figsize=(10, 7.5),
                                 gridspec_kw={"height_ratios": [3, 2, 2]})
        fig.canvas.manager.set_window_title("RehabSense live")
        self._fig = fig
        self.ax_angle, self.ax_emg, self.ax_score = axes

        rom = calib.rom
        ext_top = calib.angle_min + 0.10 * rom
        flex_bottom = calib.angle_min + 0.85 * rom

        a = self.ax_angle
        (self._l_angle,) = a.plot([], [], lw=1.8, color="#08519c")
        # The bands are fractions of this patient's calibrated ROM, never
        # absolute angles — which is why they are drawn from the record.
        a.axhspan(calib.angle_min, ext_top, color="#fdd0a2", alpha=0.45,
                  label="extended band")
        a.axhspan(flex_bottom, calib.angle_max, color="#c7e9c0", alpha=0.55,
                  label="flexed band")
        a.set_ylabel("elbow angle (deg)")
        a.set_ylim(calib.angle_min - 8, calib.angle_max + 8)
        a.legend(loc="upper left", fontsize=7, ncol=2, framealpha=0.6)
        a.grid(alpha=0.25)

        e = self.ax_emg
        (self._l_a,) = e.plot([], [], lw=1.3, color="#31a354", label="biceps")
        (self._l_b,) = e.plot([], [], lw=1.3, color="#de2d26", label="triceps")
        e.set_ylabel("envelope (% MVC)")
        e.set_ylim(0, 110)
        e.legend(loc="upper left", fontsize=7, ncol=2, framealpha=0.6)
        e.grid(alpha=0.25)

        self.ax_score.set_ylabel("score")
        self.ax_score.set_xlabel("repetition")
        self.ax_score.set_ylim(0, 105)
        self.ax_score.grid(alpha=0.25, axis="y")

        self._banner = fig.text(0.01, 0.975, "", fontsize=9, family="monospace",
                                va="top")
        fig.tight_layout(rect=(0, 0, 1, 0.955))
        self.ok = True

    def refresh(self) -> None:
        if not self.ok:
            return
        b = self.buf
        if b.t:
            t = list(b.t)
            self._l_angle.set_data(t, list(b.angle))
            self._l_a.set_data(t, list(b.env_a))
            self._l_b.set_data(t, list(b.env_b))
            for ax in (self.ax_angle, self.ax_emg):
                ax.set_xlim(t[-1] - self.window_s, t[-1] + 0.5)

        self.ax_score.clear()
        self.ax_score.set_ylabel("score")
        self.ax_score.set_xlabel("repetition")
        self.ax_score.set_ylim(0, 105)
        self.ax_score.grid(alpha=0.25, axis="y")
        if b.scores:
            xs = [s[0] for s in b.scores]
            ys = [s[1] for s in b.scores]
            # Compensated repetitions are drawn differently but they are still
            # there: nothing is discarded for bad form.
            cols = ["#bdbdbd" if s[2] else "#3182bd" for s in b.scores]
            self.ax_score.bar(xs, ys, color=cols, width=0.7)

        comp = ", ".join(p.comp_names(b.comp_flags)) or "-"
        self._banner.set_text(
            f"{_STATE_LABEL.get(b.rep_state, '?'):<14} reps {b.rep_count:>3}   "
            f"battery {b.battery_pct:>3}%   comp {comp}   {b.last_event}")
        try:
            self._fig.canvas.draw_idle()
            self._fig.canvas.flush_events()
        except Exception as exc:                      # noqa: BLE001
            print(f"  plot: stopped ({exc})")
            self.ok = False

    async def run(self, stop: asyncio.Event, fps: float = 12.0) -> None:
        period = 1.0 / fps
        while not stop.is_set() and self.ok:
            self.refresh()
            try:
                await asyncio.wait_for(stop.wait(), timeout=period)
            except asyncio.TimeoutError:
                pass

    def close(self) -> None:
        if self._fig is not None:
            try:
                import matplotlib.pyplot as plt
                plt.close(self._fig)
            except Exception:                         # noqa: BLE001
                pass


def save_summary(buf: LiveBuffer, path) -> str | None:
    """Static end-of-session summary. Works headless, so it also runs in CI."""
    try:
        import matplotlib
        matplotlib.use("Agg", force=False)
        import matplotlib.pyplot as plt
    except ImportError:
        return None
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(8, 5.5))
    if buf.scores:
        xs = [s[0] for s in buf.scores]
        ys = [s[1] for s in buf.scores]
        ax1.bar(xs, ys, color=["#bdbdbd" if s[2] else "#3182bd" for s in buf.scores])
        mean = sum(ys) / len(ys)
        ax1.axhline(mean, ls="--", lw=1, color="#737373")
        ax1.set_title(f"per-repetition score (mean {mean:.0f}; "
                      f"grey = compensation flagged)", fontsize=9)
    ax1.set_ylim(0, 105)
    ax1.set_ylabel("score")
    ax1.grid(alpha=0.25, axis="y")
    if buf.mdf:
        ax2.plot([m[0] for m in buf.mdf], [m[1] for m in buf.mdf], lw=1,
                 color="#756bb1")
    ax2.set_ylabel("median freq (Hz)")
    ax2.set_xlabel("repetition")
    ax2.grid(alpha=0.25)
    fig.tight_layout()
    fig.savefig(path, dpi=130)
    plt.close(fig)
    return str(path)
