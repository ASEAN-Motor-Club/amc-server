{
  config,
  lib,
  pkgs,
  ...
}: let
  # Live "State of the Economy" embed in the #economy Discord channel.
  # One self-updating message: the service PATCHes the message in place every
  # minute, re-rendering a matplotlib chart PNG and re-attaching it.
  channelId = "1552914696296857650";
  apiBase = "https://www.aseanmotorclub.com/api/v1/economy";
  livePage = "https://www.aseanmotorclub.com/releases/economy.html";

  renderChart = pkgs.writers.writePython3 "economy-render-chart" {
    libraries = [pkgs.python3Packages.matplotlib];
  } ''
    import json, os, sys
    from datetime import datetime, timezone

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    BG = "#0d1117"; SURFACE = "#141a23"; INK = "#e6edf3"
    MUTED = "#8b98a9"; FAINT = "#5c6878"; TRACK = "#232b37"
    GREEN = "#3fb950"; AMBER = "#d29922"; RED = "#f85149"

    os.environ.setdefault("MPLCONFIGDIR", "/tmp/mpl-config")

    NAMES = {"retail": "Retail", "construction": "Construction", "metal": "Steel & Metal",
             "energy": "Energy", "food": "Food", "mining": "Mining", "logging": "Logging",
             "furniture": "Furniture", "chemical": "Chemicals", "other": "Other"}

    def color_for(f):
        return GREEN if f >= 0.6 else AMBER if f >= 0.3 else RED

    def main(sectors_path, contributors_path, out_path):
        sectors = json.load(open(sectors_path))
        contrib = json.load(open(contributors_path))

        cap = sum(s["capacity"] for s in sectors)
        amt = sum(s["amount"] for s in sectors)
        overall = amt / cap if cap else 0
        starved = sum(s["starved_sites"] for s in sectors)
        rows = sorted(sectors, key=lambda s: s["fill"])

        fig, (ax, axlb) = plt.subplots(
            1, 2, figsize=(10.2, 4.6), dpi=110,
            gridspec_kw={"width_ratios": [1.45, 1], "wspace": 0.08},
            facecolor=BG,
        )

        ax.set_facecolor(BG)
        n = len(rows)
        ypos = list(range(n))[::-1]
        for y, s in zip(ypos, rows):
            f = s["fill"]
            c = color_for(f)
            ax.barh(y, 100, height=0.62, color=TRACK, zorder=1)
            ax.barh(y, min(f * 100, 100), height=0.62, color=c, zorder=2)
            ax.axvline(15, color=INK, alpha=0.5, lw=1, zorder=3)
            ax.text(101.5, y, f"{f*100:.0f}%", va="center", ha="left",
                    fontsize=11, fontweight="bold", color=c)
            ax.text(-2, y, NAMES.get(s["sector"], s["sector"]), va="center", ha="right",
                    fontsize=11, color=INK)
        ax.set_xlim(-26, 110)
        ax.set_ylim(-0.7, n - 0.3)
        ax.axis("off")
        ax.set_title("Input supply by sector  —  15% line = starved",
                     fontsize=10.5, color=MUTED, loc="left", pad=10)

        axlb.set_facecolor(SURFACE)
        axlb.axis("off")
        axlb.text(0.5, 0.97, f"{overall*100:.0f}%", transform=axlb.transAxes,
                  fontsize=40, fontweight="bold", color=color_for(overall), ha="center", va="top")
        axlb.text(0.5, 0.80, "overall input supply", transform=axlb.transAxes,
                  fontsize=10, color=FAINT, ha="center")
        axlb.text(0.5, 0.74, f"{starved} sites critically short", transform=axlb.transAxes,
                  fontsize=10, color=FAINT, ha="center")

        fmt = lambda v: f"{v/1e6:.1f}M" if v >= 1e6 else (f"{v/1e3:.0f}k" if v >= 1e3 else str(round(v)))
        axlb.text(0.06, 0.66, "TOP CONTRIBUTORS — 7 DAYS", transform=axlb.transAxes,
                  fontsize=9, color=MUTED, ha="left")
        y = 0.57
        for i, p in enumerate(contrib[:5], 1):
            axlb.text(0.06, y, f"{i}.  {p['name']}", transform=axlb.transAxes,
                      fontsize=11, color=INK, ha="left", fontweight="bold")
            axlb.text(0.94, y, f"{fmt(p['score'])} pts", transform=axlb.transAxes,
                      fontsize=11, color=MUTED, ha="right")
            y -= 0.085
        axlb.text(0.47, y - 0.02, "full leaderboard:  aseanmotorclub.com/releases/economy.html",
                  transform=axlb.transAxes, fontsize=8.5, color="#a8b3c2", ha="center")

        stamp = datetime.now(timezone.utc).strftime("%H:%M UTC")
        fig.suptitle(f"STATE OF THE ECONOMY   ·   {stamp}", x=0.05, y=0.985,
                     fontsize=13, fontweight="bold", color=INK, ha="left")
        fig.savefig(out_path, facecolor=BG, bbox_inches="tight")

    if __name__ == "__main__":
        main(sys.argv[1], sys.argv[2], sys.argv[3])
  '';

  buildPayload = pkgs.writers.writePython3 "economy-build-payload" { } ''
    import json, sys
    print(json.dumps({
        "embeds": [{
            "title": "State of the Economy",
            "url": "${livePage}",
            "color": 5814783,
            "description": "Live delivery-point health. Deliver to starved sectors to move the bars.",
            "image": {"url": "attachment://economy.png"},
            "footer": {"text": "updates every minute"},
        }]
    }))
  '';

  runScript = pkgs.writeShellScript "economy-monitor-run" ''
    set -uo pipefail
    TOK=$(grep '^DISCORD_TOKEN=' ${config.age.secrets.backend.path} | cut -d= -f2-)
    STATE=/var/lib/amc-economy-monitor/message-id
    DISCORD="https://discord.com/api/v10/channels/${channelId}"

    if ! ${pkgs.curl}/bin/curl -sf "${apiBase}/sectors/" -o /tmp/.econ_sec.json; then echo "sectors fetch failed"; exit 0; fi
    if ! ${pkgs.curl}/bin/curl -sf "${apiBase}/contributors/?days=7&limit=5" -o /tmp/.econ_con.json; then echo "contributors fetch failed"; exit 0; fi
    if ! ${renderChart} /tmp/.econ_sec.json /tmp/.econ_con.json /tmp/.econ_chart.png; then echo "render failed"; exit 0; fi
    if ! ${buildPayload} > /tmp/.econ_payload.json; then echo "payload build failed"; exit 0; fi

    api() { # method, url -> echoes http code; body in /tmp/.econ_resp.json
      local code
      code=$(${pkgs.curl}/bin/curl -s -X "$1" -H "Authorization: Bot $TOK" \
        -F 'payload_json=</tmp/.econ_payload.json' \
        -F 'files[0]=@/tmp/.econ_chart.png' \
        "$2" -o /tmp/.econ_resp.json -w '%{http_code}')
      echo "$code"
    }

    MID=$(cat "$STATE" 2>/dev/null || true)
    if [ -n "$MID" ]; then
      CODE=$(api PATCH "$DISCORD/messages/$MID")
      if [ "$CODE" = "429" ]; then sleep 3; CODE=$(api PATCH "$DISCORD/messages/$MID"); fi
      if [ "$CODE" = "200" ]; then echo "updated $MID"; exit 0; fi
      echo "edit failed ($CODE), posting new"
    fi
    CODE=$(api POST "$DISCORD/messages")
    if [ "$CODE" = "200" ]; then
      NEWID=$(${pkgs.python3}/bin/python3 -c "import json;print(json.load(open('/tmp/.econ_resp.json'))['id'])")
      echo "$NEWID" > "$STATE"
      echo "posted $NEWID"
    else
      echo "post failed: $CODE"
      exit 0
    fi
  '';
in {
  options.services.amc-economy-monitor = {
    enable = lib.mkEnableOption "live State-of-the-Economy Discord embed (self-updating chart, 1/min)";
  };

  config = lib.mkIf config.services.amc-economy-monitor.enable {
    systemd.services.amc-economy-monitor = {
      description = "AMC economy monitor — update the live Discord embed in #economy";
      wants = ["network-online.target"];
      after = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "amc-economy-monitor";
      };
      script = lib.getExe runScript;
    };
    systemd.timers.amc-economy-monitor = {
      description = "Update the AMC economy Discord embed every minute";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "60s";
        AccuracySec = "15s";
        Unit = "amc-economy-monitor.service";
      };
    };
  };
}
