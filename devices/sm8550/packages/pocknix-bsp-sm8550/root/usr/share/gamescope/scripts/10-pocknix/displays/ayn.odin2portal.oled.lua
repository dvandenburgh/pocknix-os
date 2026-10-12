-- AYN Odin 2 Portal: Chipone ICNA3512 OLED.
-- The panel exposes no EDID: gamescope synthesizes one (patch 0012) and matches this profile
-- on GAMESCOPE_INTERNAL_DEVICE_ID, which pocknix-steam sets to the board's POCKNIX_DEVICE
-- (0013). It supplies the colorimetry (nominal DCI-P3, not measured) and the HDR range;
-- Steam's display settings turn HDR on and off. Values from armada-os/armada's profile for
-- the same panel. The board's POCKNIX_PANEL_HDR_NITS must match max_content_light_level.
gamescope.config.known_displays.pocknix_odin2portal_icna3512 = {
    pretty_name = "AYN Odin 2 Portal OLED (ICNA3512)",
    colorimetry = {
        r = { x = 0.6800, y = 0.3200 },
        g = { x = 0.2650, y = 0.6900 },
        b = { x = 0.1500, y = 0.0600 },
        w = { x = 0.3127, y = 0.3290 },
    },
    hdr = {
        supported = true,
        eotf = gamescope.eotf.gamma22,
        max_content_light_level = 780,
        max_frame_average_luminance = 390,
        min_content_light_level = 0,
    },
    matches = function(display)
        if (display.device_id == "odin2portal") and display.internal and not display.has_edid then
            return 6000
        end
        return -1
    end,
}
debug("Registered AYN Odin 2 Portal OLED (ICNA3512) as a known display")
