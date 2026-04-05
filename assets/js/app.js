import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { CanvasHook, TimelineSlider } from "../../deps/timeless_canvas/assets/js";

const copyText = async (text) => {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }

  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "absolute";
  textarea.style.left = "-9999px";
  document.body.appendChild(textarea);
  textarea.select();
  document.execCommand("copy");
  document.body.removeChild(textarea);
};

const CanvasDebugCopy = {
  mounted() {
    this.defaultLabel = this.el.textContent.trim();

    this.onClick = async () => {
      const target = document.querySelector(this.el.dataset.target || "#canvas-svg");

      if (!target) {
        this.flashLabel("SVG missing");
        return;
      }

      try {
        await copyText(target.outerHTML);
        this.flashLabel("Copied SVG");
      } catch (_error) {
        this.flashLabel("Copy failed");
      }
    };

    this.el.addEventListener("click", this.onClick);
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick);
  },

  flashLabel(label) {
    this.el.textContent = label;
    clearTimeout(this.resetTimer);

    this.resetTimer = window.setTimeout(() => {
      this.el.textContent = this.defaultLabel;
    }, 1500);
  },
};

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { Canvas: CanvasHook, TimelineSlider: TimelineSlider, CanvasDebugCopy },
});

liveSocket.connect();
window.liveSocket = liveSocket;
