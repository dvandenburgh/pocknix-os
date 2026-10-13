# particles.awk - the boot logo's moving parts as SVG frames, laid over logo.svg: the protons and
# electrons on its orbits, and the handheld turning over to swap its left-side D-pad and stick.
# two-step loops throbber frames over a fixed 2 s, so every particle laps exactly once a loop, the
# handheld flips over and back, and the loop closes on logo.svg's own pose. Orbits, body mask and
# handheld mirror logo.svg; keep them in step.
#   awk -v frames=N -v out=DIR -f particles.awk
BEGIN {
    cx = 512.2; cy = 512.5; a = 384; b = 136; pi = atan2(0, -1)
    hx = 512.5              # the handheld's vertical centre line, the axis it turns on
    # orbit tilt (deg) | proton rest angle (deg) - its electron starts opposite, 180 deg on
    n = split("-60 -15|0 -160|60 -20", orbit, "|")
    PROTON = "26.7 #ec5129"; ELECTRON = "19.2 #1a9fff"
    W = frames / 6          # flash half-width in frames (1/3 s at 60 frames)
    F = frames / 5          # frames per turn over (0.4 s at 60 frames)
    for (f = 0; f < frames; f++) {
        # The pairs meet a quarter and three quarters of the way round; g peaks there.
        x = f - frames / 4; if (x < 0) x = -x
        y = f - 3 * frames / 4; if (y < 0) y = -y
        near = (x < y) ? x : y
        g = (near < W) ? (1 - near / W) ^ 2 : 0
        meet = (x < y) ? 90 : 270   # where on the orbit, past the proton's rest angle

        # Hold, turn over, hold, turn back: each turn starts once its half's flash has passed and
        # ends on the half's last frame. The width follows the cosine of the turn, and the layout
        # swaps edge-on, where the handheld has no width.
        stick_top = (f >= frames / 2)
        sx = 1
        p = f - (frames / 2 - F)
        if (p < 0 || p >= F) p = f - (frames - F)
        if (p >= 0 && p < F) {
            sx = cos(pi * (p + 1) / F); if (sx < 0) sx = -sx
            if (sx < 0.02) sx = 0.02   # edge-on: a sliver, as the edge of a turning card
            stick_top = (f < frames / 2) ? ((p + 1) / F >= 0.5) : ((p + 1) / F < 0.5)
        }
        turn = sprintf("translate(%.2f 0) scale(%.4f 1) translate(%.2f 0)", hx, sx, -hx)

        file = sprintf("%s/particles-%04d.svg", out, f + 1)
        print "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"776\" height=\"725\" viewBox=\"124 146 776 725\">" > file
        print "  <style>.hand{fill:none;stroke:#fff}.key{fill:#fff}.orbit{fill:none;stroke:#fff;stroke-width:7}</style>" > file
        print "  <defs>" > file
        print "    <radialGradient id=\"spark\"><stop offset=\"0\" stop-color=\"#fff\"/><stop offset=\"1\" stop-color=\"#fff\" stop-opacity=\"0\"/></radialGradient>" > file
        print "    <clipPath id=\"gap\"><rect x=\"274\" y=\"398\" width=\"477\" height=\"230\" rx=\"91\"/></clipPath>" > file
        print "    <mask id=\"behind-body\" maskUnits=\"userSpaceOnUse\" x=\"124\" y=\"146\" width=\"776\" height=\"725\">" > file
        print "      <rect x=\"124\" y=\"146\" width=\"776\" height=\"725\" fill=\"#fff\"/>" > file
        printf "      <rect x=\"283\" y=\"407\" width=\"459\" height=\"212\" rx=\"82\" fill=\"#000\" transform=\"%s\"/>\n", turn > file
        print "    </mask>" > file
        print "  </defs>" > file
        # The watermark's handheld sits under every frame: blank it, a little past the gap in
        # logo.svg's orbits (its outer stroke reaches the gap's edge, and an edge-to-edge blank
        # leaves a hairline of it), then redraw the orbits there around the turning handheld.
        print "  <rect x=\"274\" y=\"398\" width=\"477\" height=\"230\" rx=\"91\" fill=\"#000\"/>" > file
        print "  <g opacity=\"0.4\" clip-path=\"url(#gap)\" mask=\"url(#behind-body)\">" > file
        print "    <ellipse class=\"orbit\" cx=\"512.2\" cy=\"512.5\" rx=\"384\" ry=\"136\"/>" > file
        print "    <ellipse class=\"orbit\" cx=\"512.2\" cy=\"512.5\" rx=\"384\" ry=\"136\" transform=\"rotate(60 512.2 512.5)\"/>" > file
        print "    <ellipse class=\"orbit\" cx=\"512.2\" cy=\"512.5\" rx=\"384\" ry=\"136\" transform=\"rotate(-60 512.2 512.5)\"/>" > file
        print "  </g>" > file
        handheld(turn, stick_top, file)
        if (g > 0)
            printf "  <rect x=\"407\" y=\"452\" width=\"212\" height=\"122\" rx=\"8\" fill=\"#fff\" fill-opacity=\"%.3f\" transform=\"%s\"/>\n", 0.22 * g, turn > file
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
# logo.svg's handheld under <transform>. The D-pad and the left stick trade centres when
# stick_top is set; the face buttons and the right stick never move.
function handheld(transform, stick_top, file,    dx, dy, sx, sy) {
    dx = 346.8; dy = 475; sx = 373.7; sy = 557.5
    if (stick_top) { dx = 373.7; dy = 557.5; sx = 346.8; sy = 475 }
    printf "  <g transform=\"%s\">\n", transform > file
    print "    <rect class=\"hand\" x=\"286.5\" y=\"410.5\" width=\"452\" height=\"205\" rx=\"78.5\" stroke-width=\"7\"/>" > file
    print "    <rect class=\"hand\" x=\"404.5\" y=\"449.5\" width=\"217\" height=\"127\" rx=\"10.5\" stroke-width=\"5\" fill=\"#fff\" fill-opacity=\"0.05\"/>" > file
    printf "    <rect class=\"key\" x=\"%.1f\" y=\"%.1f\" width=\"46\" height=\"14\" rx=\"2.5\"/>\n", dx - 23, dy - 7 > file
    printf "    <rect class=\"key\" x=\"%.1f\" y=\"%.1f\" width=\"14\" height=\"46\" rx=\"2.5\"/>\n", dx - 7, dy - 23 > file
    print "    <circle class=\"key\" cx=\"678\" cy=\"456.5\" r=\"7\"/>" > file
    print "    <circle class=\"key\" cx=\"659.9\" cy=\"474.7\" r=\"7\"/>" > file
    print "    <circle class=\"key\" cx=\"696.1\" cy=\"474.6\" r=\"7\"/>" > file
    print "    <circle class=\"key\" cx=\"678.1\" cy=\"492.7\" r=\"7\"/>" > file
    printf "    <circle class=\"hand\" cx=\"%.1f\" cy=\"%.1f\" r=\"18.7\" stroke-width=\"5\"/>\n", sx, sy > file
    print "    <circle class=\"hand\" cx=\"650.9\" cy=\"557.5\" r=\"18.7\" stroke-width=\"5\"/>" > file
    printf "    <circle class=\"key\" cx=\"%.1f\" cy=\"%.1f\" r=\"5\"/>\n", sx, sy > file
    print "    <circle class=\"key\" cx=\"650.9\" cy=\"557.5\" r=\"5\"/>" > file
    print "  </g>" > file
}
function px(t, r) { return cx + a * cos(t) * cos(r) - b * sin(t) * sin(r) }
function py(t, r) { return cy + a * cos(t) * sin(r) + b * sin(t) * cos(r) }
