import { definePlugin } from "@decky/api";
import { Content } from "./Content";
import { patchLibraryContextMenu } from "./lib/contextMenu";
import { registerTouchLifetime } from "./lib/touch";

export default definePlugin(() => {
  const unpatchContextMenu = patchLibraryContextMenu();
  const unregisterTouch = registerTouchLifetime();
  return {
    name: "Pocknix Control",
    content: <Content />,
    icon: <div style={{ fontWeight: 700 }}>P</div>,
    alwaysRender: true,
    onDismount() {
      unpatchContextMenu();
      unregisterTouch();
    },
  };
});
