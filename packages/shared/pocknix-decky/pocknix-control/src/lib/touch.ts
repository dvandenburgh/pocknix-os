import { gameLifetime } from "../backend";
import { currentGame } from "./games";

// Reports game start/stop to the backend, which owns the touchscreen tweak (touch.py). Covers
// every Steam launch, Proton or not, since the appid comes from Steam itself. Shortcut appids
// are unsigned above 2^31, hence the >>> 0 (see nonSteamShortcuts).
export function registerTouchLifetime(): () => void {
  const report = (appid: string, running: boolean) => gameLifetime(appid, running).catch(() => {});
  // A plugin reload mid-game misses the start notification.
  const running = currentGame();
  if (running) report(running.appid, true);
  try {
    const handle = window.SteamClient?.GameSessions?.RegisterForAppLifetimeNotifications?.((update: any) => {
      report(String(Number(update?.unAppID) >>> 0), !!update?.bRunning);
    });
    return () => handle?.unregister?.();
  } catch (error) {
    return () => {};
  }
}
