# particles.awk - the boot logo's moving particles as SVG frames, laid over logo.svg's orbits.
# two-step loops throbber frames over a fixed 2 s, so every particle laps exactly once a loop and
# the loop closes. Orbits, body mask and screen box mirror logo.svg; keep them in step.
#   awk -v frames=N -v out=DIR -f particles.awk
BEGIN {
    cx = 512.2; cy = 512.5; a = 384; b = 136; pi = atan2(0, -1)
    # orbit tilt (deg) | proton rest angle (deg) - its electron starts opposite, 180 deg on
    n = split("-60 -15|0 -160|60 -20", orbit, "|")
    PROTON = "26.7 #ec5129"; ELECTRON = "19.2 #1a9fff"
    W = frames / 6          # flash half-width in frames (1/3 s at 60 frames)
    for (f = 0; f < frames; f++) {
        # The pairs meet a quarter and three quarters of the way round; g peaks there.
        x = f - frames / 4; if (x < 0) x = -x
        y = f - 3 * frames / 4; if (y < 0) y = -y
        near = (x < y) ? x : y
        g = (near < W) ? (1 - near / W) ^ 2 : 0
        meet = (x < y) ? 90 : 270   # where on the orbit, past the proton's rest angle

        file = sprintf("%s/particles-%04d.svg", out, f + 1)
        print "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"776\" height=\"725\" viewBox=\"124 146 776 725\">" > file
        print "  <defs>" > file
        print "    <radialGradient id=\"spark\"><stop offset=\"0\" stop-color=\"#fff\"/><stop offset=\"1\" stop-color=\"#fff\" stop-opacity=\"0\"/></radialGradient>" > file
        print "    <mask id=\"behind-body\" maskUnits=\"userSpaceOnUse\" x=\"124\" y=\"146\" width=\"776\" height=\"725\">" > file
        print "      <rect x=\"124\" y=\"146\" width=\"776\" height=\"725\" fill=\"#fff\"/>" > file
        print "      <rect x=\"283\" y=\"407\" width=\"459\" height=\"212\" rx=\"82\" fill=\"#000\"/>" > file
        print "    </mask>" > file
        print "  </defs>" > file
        if (g > 0)
            printf "  <rect x=\"407\" y=\"452\" width=\"212\" height=\"122\" rx=\"8\" fill=\"#fff\" fill-opacity=\"%.3f\"/>\n", 0.22 * g > file
        print "  <g mask=\"url(#behind-body)\">" > file
        for (i = 1; i <= n; i++) {
            split(orbit[i], o, " ")
            r = o[1] * pi / 180
            if (g > 0) {
                t = (o[2] + meet) * pi / 180
                printf "    <circle cx=\"%.2f\" cy=\"%.2f\" r=\"%.1f\" fill=\"url(#spark)\" opacity=\"%.3f\"/>\n", \
                    px(t, r), py(t, r), 30 + 26 * (1 - g), g > file
            }
            t = (o[2] / 180 + 2 * f / frames) * pi              # proton: +1 lap a loop
            printf "    <circle cx=\"%.2f\" cy=\"%.2f\" r=\"%s\" fill=\"%s\"/>\n", px(t, r), py(t, r), \
                substr(PROTON, 1, index(PROTON, " ") - 1), substr(PROTON, index(PROTON, " ") + 1) > file
            t = (o[2] / 180 + 1 - 2 * f / frames) * pi          # electron: opposite, -1 lap
            printf "    <circle cx=\"%.2f\" cy=\"%.2f\" r=\"%s\" fill=\"%s\"/>\n", px(t, r), py(t, r), \
                substr(ELECTRON, 1, index(ELECTRON, " ") - 1), substr(ELECTRON, index(ELECTRON, " ") + 1) > file
        }
        print "  </g>\n</svg>" > file
        close(file)
    }
}
function px(t, r) { return cx + a * cos(t) * cos(r) - b * sin(t) * sin(r) }
function py(t, r) { return cy + a * cos(t) * sin(r) + b * sin(t) * cos(r) }
