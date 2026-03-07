import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { CanvasHook, TimelineSlider } from "../../deps/timeless_canvas/assets/js";

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { Canvas: CanvasHook, TimelineSlider: TimelineSlider },
});

liveSocket.connect();
window.liveSocket = liveSocket;
