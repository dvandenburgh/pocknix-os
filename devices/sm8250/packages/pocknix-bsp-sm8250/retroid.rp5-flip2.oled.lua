-- Retroid Pocket 5 and Flip 2: CH13726A OLED. The Visionox variants (rp5-visionox, rpflip2-visionox) use another panel and get no profile.
-- The panel exposes no EDID: gamescope synthesizes one (patch 0012) and matches this profile
-- on GAMESCOPE_INTERNAL_DEVICE_ID, which pocknix-steam sets to the board's POCKNIX_DEVICE
-- (0013). It supplies the colorimetry (nominal DCI-P3, not measured) and the HDR range;
-- Steam's display settings turn HDR on and off. Values from armada-os/armada's profile for
-- the same panel. The board's POCKNIX_PANEL_HDR_NITS must match max_content_light_level.
gamescope.config.known_displays.pocknix_rp5_flip2_ch13726a = {
    pretty_name = "Retroid Pocket 5 / Flip 2 OLED (CH13726A)",
    colorimetry = {
        r = { x = 0.6800, y = 0.3200 },
        g = { x = 0.2650, y = 0.6900 },
        b = { x = 0.1500, y = 0.0600 },
        w = { x = 0.3127, y = 0.3290 },
    },
    hdr = {
        supported = true,
        eotf = gamescope.eotf.gamma22,
        max_content_light_level = 580,
        max_frame_average_luminance = 290,
        min_content_light_level = 0,
    },
    matches = function(display)
        if (display.device_id == "rp5" or display.device_id == "rpflip2") and display.internal and not display.has_edid then
            return 6000
        end
        return -1
    end,
}
debug("Registered Retroid Pocket 5 / Flip 2 OLED (CH13726A) as a known display")
