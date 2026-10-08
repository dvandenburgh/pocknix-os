# electrons.awk - the boot logo's electrons as SVG frames, laid over logo.svg's orbits.
# two-step loops throbber frames over a fixed 2 s, so each electron laps its orbit once per
# loop and the loop closes; frame 1 is the rest pose. Orbit geometry and the body mask
# mirror logo.svg - change both together.   awk -v frames=N -v out=DIR -f electrons.awk
BEGIN {
    cx = 512.2; cy = 512.5; a = 384; b = 136; pi = atan2(0, -1)
    # orbit tilt (deg) | rest angle on the orbit (deg) | radius | colour
    n = split("-60 -15 26.7 #ec5129|0 -160 26.7 #ec5129|60 -20 26.7 #ec5129|" \
              "60 160 19.2 #1a9fff|0 20 19.2 #1a9fff|-60 165 19.2 #1a9fff", e, "|")
    for (f = 0; f < frames; f++) {
        file = sprintf("%s/electrons-%04d.svg", out, f + 1)
        print "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"776\" height=\"725\" viewBox=\"124 146 776 725\">" > file
        print "  <mask id=\"behind-body\" maskUnits=\"userSpaceOnUse\" x=\"124\" y=\"146\" width=\"776\" height=\"725\">" > file
        print "    <rect x=\"124\" y=\"146\" width=\"776\" height=\"725\" fill=\"#fff\"/>" > file
        print "    <rect x=\"283\" y=\"407\" width=\"459\" height=\"212\" rx=\"82\" fill=\"#000\"/>" > file
        print "  </mask>" > file
        print "  <g mask=\"url(#behind-body)\">" > file
        for (i = 1; i <= n; i++) {
            split(e[i], p, " ")
            t = (p[2] / 180 + 2 * f / frames) * pi; r = p[1] * pi / 180
            u = a * cos(t); v = b * sin(t)
            printf "    <circle cx=\"%.2f\" cy=\"%.2f\" r=\"%s\" fill=\"%s\"/>\n", \
                cx + u * cos(r) - v * sin(r), cy + u * sin(r) + v * cos(r), p[3], p[4] > file
        }
        print "  </g>\n</svg>" > file
        close(file)
    }
}
