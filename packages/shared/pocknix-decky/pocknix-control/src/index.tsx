import { definePlugin } from "@decky/api";
import { Content } from "./Content";
import { getConfig } from "./backend";
import { installedSteamGames, isGame, nonSteamShortcuts } from "./lib/games";
import { registerDownloadWrapper, wrapAllGames, wrapShortcuts } from "./lib/launchOptions";
import { patchLibraryContextMenu } from "./lib/contextMenu";
import { registerTouchLifetime } from "./lib/touch";

export default definePlugin(() => {
  const unpatchContextMenu = patchLibraryContextMenu();
  const unregisterTouch = registerTouchLifetime();
  const unregisterDownloads = registerDownloadWrapper((appid) => isGame(appid));
  getConfig()
    .then((config) => wrapAllGames(installedSteamGames(config)))
    .then(() => wrapShortcuts(nonSteamShortcuts().map((shortcut) => shortcut.appid)))
    .catch(() => {});
  return {
    name: "Pocknix Control",
    content: <Content />,
    icon: <div style={{ fontWeight: 700 }}>P</div>,
    alwaysRender: true,
    onDismount() {
      unpatchContextMenu();
      unregisterTouch();
      unregisterDownloads();
    },
  };
});
