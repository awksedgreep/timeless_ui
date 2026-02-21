/**
 * Canvas hook: pan, zoom, element drag, click detection, resize,
 * connection clicks, connect mode temp line, keyboard shortcuts.
 *
 * Interaction pattern: optimistic + authoritative.
 * Visual changes applied instantly during drag (0ms latency),
 * final state pushed to server on pointerup. Server re-renders
 * with authoritative positions. Persistence handled server-side via Ecto.
 */
const CanvasHook = {
  mounted() {
    this.svg = this.el;
    this.dragging = null; // null | {type: "pan"|"element"|"handle"|"marquee", ...}
    this.startClient = null; // {x, y} in client pixels
    this.lastClient = null;
    this.clickThreshold = 2; // px
    this.tempLine = null; // SVG line for connect mode
    this.marqueeRect = null; // SVG rect for marquee selection
    this._lastClickId = null; // track element clicks for dblclick detection
    this._lastClickTime = 0;

    this.svg.addEventListener("pointerdown", (e) => this.onPointerDown(e));
    this.svg.addEventListener("pointermove", (e) => this.onPointerMove(e));
    this.svg.addEventListener("pointerup", (e) => this.onPointerUp(e));
    this.svg.addEventListener("pointerleave", (e) => this.onPointerUp(e));
    this.svg.addEventListener("wheel", (e) => this.onWheel(e), {
      passive: false,
    });

    // Prevent context menu on canvas
    this.svg.addEventListener("contextmenu", (e) => e.preventDefault());

    this._zoomDebounce = null;

    // Keyboard shortcuts
    this._onKeyDown = (e) => this.onKeyDown(e);
    document.addEventListener("keydown", this._onKeyDown);

  },

  updated() {
    // After drop: server has patched new coordinates, remove drag transforms
    if (this._pendingDrop) {
      for (const id of this._pendingDrop.ids) {
        const group = this.svg.querySelector(`[data-element-id="${id}"]`);
        if (group) group.removeAttribute("transform");
      }
      this._pendingDrop = null;
      return;
    }
    // Mid-drag: re-apply transform after LiveView patches
    if (this.dragging && this.dragging.type === "element") {
      for (const id of this.dragging.groupIds) {
        const group = this.svg.querySelector(`[data-element-id="${id}"]`);
        if (group) {
          group.parentNode.appendChild(group);
          group.setAttribute(
            "transform",
            `translate(${this.dragging.totalDx}, ${this.dragging.totalDy})`,
          );
        }
      }
      // Update primary group reference
      const primaryGroup = this.svg.querySelector(`[data-element-id="${this.dragging.id}"]`);
      if (primaryGroup) this.dragging.group = primaryGroup;
    }
  },

  destroyed() {
    document.removeEventListener("keydown", this._onKeyDown);
  },

  // --- Helpers ---

  getViewBox() {
    const vb = this.svg.viewBox.baseVal;
    return { minX: vb.x, minY: vb.y, width: vb.width, height: vb.height };
  },

  setViewBox(minX, minY, width, height) {
    const vb = this.svg.viewBox.baseVal;
    vb.x = minX;
    vb.y = minY;
    vb.width = width;
    vb.height = height;
  },

  clientToSvgDelta(dxPx, dyPx) {
    const vb = this.getViewBox();
    const rect = this.svg.getBoundingClientRect();
    return {
      dx: dxPx * (vb.width / rect.width),
      dy: dyPx * (vb.height / rect.height),
    };
  },

  clientToSvg(clientX, clientY) {
    const pt = this.svg.createSVGPoint();
    pt.x = clientX;
    pt.y = clientY;
    const ctm = this.svg.getScreenCTM().inverse();
    const svgPt = pt.matrixTransform(ctm);
    return { x: svgPt.x, y: svgPt.y };
  },

  getMode() {
    return this.svg.dataset.mode || "select";
  },

  // --- Pointer Events ---

  onPointerDown(e) {
    if (e.button !== 0) return; // left button only
    this.svg.setPointerCapture(e.pointerId);
    this.startClient = { x: e.clientX, y: e.clientY };
    this.lastClient = { x: e.clientX, y: e.clientY };

    // Check if clicking a resize handle
    const handle = e.target.closest("[data-handle]");
    if (handle) {
      const elGroup = handle.closest("[data-element-id]");
      const id = elGroup?.dataset.elementId;
      if (id) {
        const body = elGroup.querySelector(".canvas-element__body");
        let w0 = parseFloat(body.getAttribute("width") || body.getAttribute("rx")) * 2 || 160;
        let h0 = parseFloat(body.getAttribute("height") || body.getAttribute("ry")) * 2 || 80;
        // For database cylinders, use the rect portion
        const bodyRect = elGroup.querySelector(".canvas-element__body-rect");
        if (bodyRect) {
          w0 = parseFloat(bodyRect.getAttribute("width"));
          h0 = parseFloat(bodyRect.getAttribute("height")) + 30;
        } else if (body.tagName === "rect") {
          w0 = parseFloat(body.getAttribute("width"));
          h0 = parseFloat(body.getAttribute("height"));
        }
        this.dragging = {
          type: "handle",
          id,
          startWidth: w0,
          startHeight: h0,
          origWidth: w0,
          origHeight: h0,
        };
        return;
      }
    }

    // Check if clicking a connection
    const connGroup = e.target.closest("[data-connection-id]");
    if (connGroup) {
      const id = connGroup.dataset.connectionId;
      this.dragging = { type: "connection_click", id };
      return;
    }

    // Check if clicking an element
    const elGroup = e.target.closest("[data-element-id]");
    if (elGroup) {
      const id = elGroup.dataset.elementId;
      // Collect all selected element groups for group drag
      const selectedGroups = this.getSelectedElementGroups();
      const isSelected = selectedGroups.some((g) => g.dataset.elementId === id);
      // If element is part of a multi-selection, drag all; otherwise just this one
      const groupIds =
        isSelected && selectedGroups.length > 1
          ? selectedGroups.map((g) => g.dataset.elementId)
          : [id];
      // Move dragged elements to end of SVG so they render on top
      for (const gid of groupIds) {
        const g = this.svg.querySelector(`[data-element-id="${gid}"]`);
        if (g) g.parentNode.appendChild(g);
      }
      const svgStart = this.clientToSvg(e.clientX, e.clientY);
      this.dragging = {
        type: "element",
        id,
        group: elGroup,
        groupIds,
        totalDx: 0,
        totalDy: 0,
        svgStart,
        shiftKey: e.shiftKey,
      };
      return;
    }

    // In select mode, start marquee selection; otherwise pan
    if (this.getMode() === "select") {
      const svgStart = this.clientToSvg(e.clientX, e.clientY);
      this.dragging = { type: "marquee", svgStart, shiftKey: e.shiftKey };
    } else {
      this.dragging = { type: "pan" };
    }
  },

  onPointerMove(e) {
    if (!this.dragging) {
      // In connect mode, draw temp line from source to cursor
      if (this.getMode() === "connect" && this.svg.dataset.connectFrom) {
        this.updateTempLine(e.clientX, e.clientY);
      }
      return;
    }

    const dxPx = e.clientX - this.lastClient.x;
    const dyPx = e.clientY - this.lastClient.y;

    if (this.dragging.type === "pan") {
      const delta = this.clientToSvgDelta(-dxPx, -dyPx);
      const vb = this.getViewBox();
      this.setViewBox(
        vb.minX + delta.dx,
        vb.minY + delta.dy,
        vb.width,
        vb.height,
      );
    } else if (this.dragging.type === "element") {
      // Don't drag elements in connect mode
      if (this.getMode() !== "connect") {
        // Compute total delta from absolute SVG positions (no accumulation drift)
        const svgNow = this.clientToSvg(e.clientX, e.clientY);
        this.dragging.totalDx = svgNow.x - this.dragging.svgStart.x;
        this.dragging.totalDy = svgNow.y - this.dragging.svgStart.y;
        // Apply transform to all elements in the drag group
        for (const gid of this.dragging.groupIds) {
          const g = this.svg.querySelector(`[data-element-id="${gid}"]`);
          if (g) {
            g.setAttribute(
              "transform",
              `translate(${this.dragging.totalDx}, ${this.dragging.totalDy})`,
            );
          }
        }
      }
    } else if (this.dragging.type === "marquee") {
      const svgNow = this.clientToSvg(e.clientX, e.clientY);
      this.updateMarquee(this.dragging.svgStart, svgNow);
    } else if (this.dragging.type === "handle") {
      const delta = this.clientToSvgDelta(dxPx, dyPx);
      this.dragging.startWidth += delta.dx;
      this.dragging.startHeight += delta.dy;
      this.resizeElementVisual(
        this.dragging.id,
        Math.max(this.dragging.startWidth, 20),
        Math.max(this.dragging.startHeight, 20),
      );
    }

    this.lastClient = { x: e.clientX, y: e.clientY };
  },

  onPointerUp(e) {
    if (!this.dragging) return;

    const totalDxPx = e.clientX - this.startClient.x;
    const totalDyPx = e.clientY - this.startClient.y;
    const dist = Math.sqrt(totalDxPx * totalDxPx + totalDyPx * totalDyPx);
    const isClick = dist < this.clickThreshold;

    if (this.dragging.type === "pan") {
      if (isClick) {
        // Click on empty canvas
        const svgPt = this.clientToSvg(e.clientX, e.clientY);
        this.pushEvent("canvas:click", { x: svgPt.x, y: svgPt.y });
        this.removeTempLine();
      } else {
        // Push final pan position
        const vb = this.getViewBox();
        this.pushEvent("canvas:zoom", {
          min_x: vb.minX,
          min_y: vb.minY,
          width: vb.width,
          height: vb.height,
        });
      }
    } else if (this.dragging.type === "marquee") {
      this.removeMarquee();
      if (isClick) {
        // Click on empty canvas - clear selection
        const svgPt = this.clientToSvg(e.clientX, e.clientY);
        this.pushEvent("canvas:click", { x: svgPt.x, y: svgPt.y });
      } else {
        // Compute which elements intersect the marquee
        const svgEnd = this.clientToSvg(e.clientX, e.clientY);
        const ids = this.getElementsInRect(this.dragging.svgStart, svgEnd);
        if (ids.length > 0) {
          this.pushEvent("marquee:select", { ids });
        } else {
          this.pushEvent("canvas:deselect", {});
        }
      }
    } else if (this.dragging.type === "element") {
      if (isClick) {
        // Remove transforms from all group members
        for (const gid of this.dragging.groupIds) {
          const g = this.svg.querySelector(`[data-element-id="${gid}"]`);
          if (g) g.removeAttribute("transform");
        }

        // Detect double-click: same element within 400ms
        const now = Date.now();
        const id = this.dragging.id;
        if (this._lastClickId === id && now - this._lastClickTime < 400) {
          this.pushEvent("element:dblclick", { id });
          this._lastClickId = null;
          this._lastClickTime = 0;
        } else {
          this._lastClickId = id;
          this._lastClickTime = now;
          if (this.dragging.shiftKey) {
            this.pushEvent("element:shift_select", { id });
          } else {
            this.pushEvent("element:select", { id });
          }
        }
      } else if (this.getMode() !== "connect") {
        // Keep transform until server patches with new coordinates
        this._pendingDrop = { ids: this.dragging.groupIds };
        this.pushEvent("element:move", {
          id: this.dragging.id,
          dx: this.dragging.totalDx,
          dy: this.dragging.totalDy,
        });
      } else {
        for (const gid of this.dragging.groupIds) {
          const g = this.svg.querySelector(`[data-element-id="${gid}"]`);
          if (g) g.removeAttribute("transform");
        }
      }
    } else if (this.dragging.type === "handle") {
      this.pushEvent("element:resize", {
        id: this.dragging.id,
        width: Math.max(this.dragging.startWidth, 20),
        height: Math.max(this.dragging.startHeight, 20),
      });
    } else if (this.dragging.type === "connection_click") {
      if (isClick) {
        this.pushEvent("connection:select", { id: this.dragging.id });
      }
    }

    this.dragging = null;
    this.startClient = null;
    this.lastClient = null;
    this.svg.releasePointerCapture(e.pointerId);
  },

  // --- Zoom ---

  onWheel(e) {
    e.preventDefault();
    const factor = e.deltaY > 0 ? 1.1 : 0.9;
    const svgPt = this.clientToSvg(e.clientX, e.clientY);
    const vb = this.getViewBox();

    const newWidth = vb.width * factor;
    const newHeight = vb.height * factor;

    // Enforce limits
    if (newWidth < 100 || newWidth > 50000) return;

    const newMinX = svgPt.x - (svgPt.x - vb.minX) * factor;
    const newMinY = svgPt.y - (svgPt.y - vb.minY) * factor;

    this.setViewBox(newMinX, newMinY, newWidth, newHeight);

    // Debounce push to server
    clearTimeout(this._zoomDebounce);
    this._zoomDebounce = setTimeout(() => {
      const final = this.getViewBox();
      this.pushEvent("canvas:zoom", {
        min_x: final.minX,
        min_y: final.minY,
        width: final.width,
        height: final.height,
      });
    }, 100);
  },

  // --- Keyboard Shortcuts ---

  onKeyDown(e) {
    // Don't intercept if typing in an input/textarea/select
    if (
      e.target.tagName === "INPUT" ||
      e.target.tagName === "TEXTAREA" ||
      e.target.tagName === "SELECT"
    ) {
      return;
    }

    const ctrl = e.ctrlKey || e.metaKey;

    if (e.key === "Delete" || e.key === "Backspace") {
      e.preventDefault();
      this.pushEvent("delete_selected", {});
    } else if (e.key === "Escape") {
      e.preventDefault();
      this.pushEvent("canvas:deselect", {});
      this.removeTempLine();
    } else if (e.key === "a" && ctrl) {
      e.preventDefault();
      this.pushEvent("select_all", {});
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      const amount = e.shiftKey ? -1 : -(parseInt(this.svg.dataset.gridSize) || 20);
      this.pushEvent("element:nudge", { dx: 0, dy: amount });
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      const amount = e.shiftKey ? 1 : parseInt(this.svg.dataset.gridSize) || 20;
      this.pushEvent("element:nudge", { dx: 0, dy: amount });
    } else if (e.key === "ArrowLeft") {
      e.preventDefault();
      const amount = e.shiftKey ? -1 : -(parseInt(this.svg.dataset.gridSize) || 20);
      this.pushEvent("element:nudge", { dx: amount, dy: 0 });
    } else if (e.key === "ArrowRight") {
      e.preventDefault();
      const amount = e.shiftKey ? 1 : parseInt(this.svg.dataset.gridSize) || 20;
      this.pushEvent("element:nudge", { dx: amount, dy: 0 });
    } else if ((e.key === "+" || e.key === "=") && !ctrl) {
      e.preventDefault();
      this.zoomByFactor(0.9);
    } else if (e.key === "-" && !ctrl) {
      e.preventDefault();
      this.zoomByFactor(1.1);
    } else if (e.key === "z" && ctrl && e.shiftKey) {
      e.preventDefault();
      this.pushEvent("canvas:redo", {});
    } else if (e.key === "y" && ctrl) {
      e.preventDefault();
      this.pushEvent("canvas:redo", {});
    } else if (e.key === "z" && ctrl) {
      e.preventDefault();
      this.pushEvent("canvas:undo", {});
    } else if (e.key === "s" && ctrl) {
      e.preventDefault();
      this.pushEvent("canvas:save", {});
    } else if (e.key === " ") {
      e.preventDefault();
      this.pushEvent("timeline:play_pause", {});
    } else if (e.key === "l" || e.key === "L") {
      e.preventDefault();
      this.pushEvent("timeline:go_live", {});
    }
  },

  zoomByFactor(factor) {
    const rect = this.svg.getBoundingClientRect();
    const centerX = rect.left + rect.width / 2;
    const centerY = rect.top + rect.height / 2;
    const svgPt = this.clientToSvg(centerX, centerY);
    const vb = this.getViewBox();

    const newWidth = vb.width * factor;
    const newHeight = vb.height * factor;
    if (newWidth < 100 || newWidth > 50000) return;

    const newMinX = svgPt.x - (svgPt.x - vb.minX) * factor;
    const newMinY = svgPt.y - (svgPt.y - vb.minY) * factor;
    this.setViewBox(newMinX, newMinY, newWidth, newHeight);

    this.pushEvent("canvas:zoom", {
      min_x: newMinX,
      min_y: newMinY,
      width: newWidth,
      height: newHeight,
    });
  },

  // --- Connect Mode Temp Line ---

  updateTempLine(clientX, clientY) {
    const sourceId = this.svg.dataset.connectFrom;
    if (!sourceId) return;

    const sourceGroup = this.svg.querySelector(
      `[data-element-id="${sourceId}"]`,
    );
    if (!sourceGroup) return;

    const body = sourceGroup.querySelector(".canvas-element__body");
    if (!body) return;

    let sx, sy;
    if (body.tagName === "ellipse") {
      sx = parseFloat(body.getAttribute("cx"));
      sy = parseFloat(body.getAttribute("cy"));
    } else {
      sx =
        parseFloat(body.getAttribute("x")) +
        parseFloat(body.getAttribute("width")) / 2;
      sy =
        parseFloat(body.getAttribute("y")) +
        parseFloat(body.getAttribute("height")) / 2;
    }

    const cursor = this.clientToSvg(clientX, clientY);

    if (!this.tempLine) {
      this.tempLine = document.createElementNS(
        "http://www.w3.org/2000/svg",
        "line",
      );
      this.tempLine.setAttribute("class", "canvas-temp-connection");
      this.tempLine.setAttribute("stroke", "#8888aa");
      this.tempLine.setAttribute("stroke-width", "2");
      this.tempLine.setAttribute("stroke-dasharray", "6 4");
      this.tempLine.setAttribute("pointer-events", "none");
      this.svg.appendChild(this.tempLine);
    }

    this.tempLine.setAttribute("x1", sx);
    this.tempLine.setAttribute("y1", sy);
    this.tempLine.setAttribute("x2", cursor.x);
    this.tempLine.setAttribute("y2", cursor.y);
  },

  removeTempLine() {
    if (this.tempLine) {
      this.tempLine.remove();
      this.tempLine = null;
    }
  },

  // --- Visual Updates (optimistic, no server) ---

  moveElementVisual(group, dx, dy) {
    // Skip elements inside transform-based icon groups (they use local coords)
    const insideTransform = (el) => el.closest(".canvas-element__icon");

    group.querySelectorAll("[x]").forEach((el) => {
      if (!insideTransform(el))
        el.setAttribute("x", parseFloat(el.getAttribute("x")) + dx);
    });
    group.querySelectorAll("[y]").forEach((el) => {
      if (!insideTransform(el))
        el.setAttribute("y", parseFloat(el.getAttribute("y")) + dy);
    });
    group.querySelectorAll("[cx]").forEach((el) => {
      if (!insideTransform(el))
        el.setAttribute("cx", parseFloat(el.getAttribute("cx")) + dx);
    });
    group.querySelectorAll("[cy]").forEach((el) => {
      if (!insideTransform(el))
        el.setAttribute("cy", parseFloat(el.getAttribute("cy")) + dy);
    });
    // Move polyline/polygon points (graph lines only, skip icon internals)
    group.querySelectorAll("polyline[points], polygon[points]").forEach((el) => {
      if (insideTransform(el)) return;
      const pts = el.getAttribute("points").trim();
      if (!pts) return;
      const shifted = pts.split(/\s+/).map((pair) => {
        const [px, py] = pair.split(",");
        return `${parseFloat(px) + dx},${parseFloat(py) + dy}`;
      }).join(" ");
      el.setAttribute("points", shifted);
    });
    // Move transform-based icons as a whole
    group.querySelectorAll("[transform]").forEach((el) => {
      const t = el.getAttribute("transform");
      const match = t.match(/translate\(([^,]+),\s*([^)]+)\)/);
      if (match) {
        const nx = parseFloat(match[1]) + dx;
        const ny = parseFloat(match[2]) + dy;
        el.setAttribute("transform", `translate(${nx}, ${ny})`);
      }
    });
  },

  // --- Marquee Selection ---

  updateMarquee(start, current) {
    const x = Math.min(start.x, current.x);
    const y = Math.min(start.y, current.y);
    const w = Math.abs(current.x - start.x);
    const h = Math.abs(current.y - start.y);

    if (!this.marqueeRect) {
      this.marqueeRect = document.createElementNS(
        "http://www.w3.org/2000/svg",
        "rect",
      );
      this.marqueeRect.setAttribute("class", "canvas-marquee");
      this.marqueeRect.setAttribute("fill", "rgba(99, 102, 241, 0.1)");
      this.marqueeRect.setAttribute("stroke", "#6366f1");
      this.marqueeRect.setAttribute("stroke-width", "1");
      this.marqueeRect.setAttribute("stroke-dasharray", "4 2");
      this.marqueeRect.setAttribute("pointer-events", "none");
      this.svg.appendChild(this.marqueeRect);
    }

    this.marqueeRect.setAttribute("x", x);
    this.marqueeRect.setAttribute("y", y);
    this.marqueeRect.setAttribute("width", w);
    this.marqueeRect.setAttribute("height", h);
  },

  removeMarquee() {
    if (this.marqueeRect) {
      this.marqueeRect.remove();
      this.marqueeRect = null;
    }
  },

  getSelectedElementGroups() {
    return Array.from(
      this.svg.querySelectorAll(".canvas-element--selected[data-element-id]"),
    );
  },

  getElementsInRect(start, end) {
    const minX = Math.min(start.x, end.x);
    const minY = Math.min(start.y, end.y);
    const maxX = Math.max(start.x, end.x);
    const maxY = Math.max(start.y, end.y);

    const ids = [];
    this.svg.querySelectorAll("[data-element-id]").forEach((group) => {
      const bounds = this.getElementBounds(group);
      if (!bounds) return;

      // Check intersection (any overlap)
      if (
        bounds.x + bounds.w > minX &&
        bounds.x < maxX &&
        bounds.y + bounds.h > minY &&
        bounds.y < maxY
      ) {
        ids.push(group.dataset.elementId);
      }
    });
    return ids;
  },

  getElementBounds(group) {
    // For database (cylinder): use body-rect which spans the full width, plus ellipse caps
    const bodyRect = group.querySelector(".canvas-element__body-rect");
    if (bodyRect) {
      const x = parseFloat(bodyRect.getAttribute("x"));
      const y = parseFloat(bodyRect.getAttribute("y")) - 15;
      const w = parseFloat(bodyRect.getAttribute("width"));
      const h = parseFloat(bodyRect.getAttribute("height")) + 30;
      return { x, y, w, h };
    }

    const body = group.querySelector(".canvas-element__body");
    if (!body) return null;

    if (body.tagName === "rect") {
      return {
        x: parseFloat(body.getAttribute("x")),
        y: parseFloat(body.getAttribute("y")),
        w: parseFloat(body.getAttribute("width")),
        h: parseFloat(body.getAttribute("height")),
      };
    }

    // Fallback for ellipse-only elements
    const cx = parseFloat(body.getAttribute("cx"));
    const cy = parseFloat(body.getAttribute("cy"));
    const rx = parseFloat(body.getAttribute("rx"));
    const ry = parseFloat(body.getAttribute("ry"));
    return { x: cx - rx, y: cy - ry, w: rx * 2, h: ry * 2 };
  },

  resizeElementVisual(id, width, height) {
    const group = this.svg.querySelector(`[data-element-id="${id}"]`);
    if (!group) return;

    const body = group.querySelector(".canvas-element__body");
    if (!body) return;

    // Get element origin (top-left corner)
    let x, y;
    if (body.tagName === "ellipse") {
      // Database: origin from the body-rect or computed from ellipse
      const bodyRect = group.querySelector(".canvas-element__body-rect");
      if (bodyRect) {
        x = parseFloat(bodyRect.getAttribute("x"));
        y = parseFloat(body.getAttribute("cy")) - 15; // top ellipse cy - ry
      } else {
        x = parseFloat(body.getAttribute("cx")) - parseFloat(body.getAttribute("rx"));
        y = parseFloat(body.getAttribute("cy")) - parseFloat(body.getAttribute("ry"));
      }
    } else {
      x = parseFloat(body.getAttribute("x"));
      y = parseFloat(body.getAttribute("y"));
    }

    // --- Resize the body shape ---
    if (body.tagName === "rect") {
      body.setAttribute("width", width);
      body.setAttribute("height", height);

      // Update clip paths (graph, log_stream, trace_stream)
      group.querySelectorAll("clipPath rect").forEach((r) => {
        r.setAttribute("width", width);
        r.setAttribute("height", height);
      });
    } else if (body.tagName === "ellipse") {
      // Database cylinder
      body.setAttribute("cx", x + width / 2);
      body.setAttribute("rx", width / 2);

      const bodyRect = group.querySelector(".canvas-element__body-rect");
      if (bodyRect) {
        bodyRect.setAttribute("width", width);
        bodyRect.setAttribute("height", height - 30);
      }

      const bodyBottom = group.querySelector(".canvas-element__body-bottom");
      if (bodyBottom) {
        bodyBottom.setAttribute("cx", x + width / 2);
        bodyBottom.setAttribute("cy", y + height - 15);
        bodyBottom.setAttribute("rx", width / 2);
      }

      // Bottom outline ellipse (the brightness filter one)
      group.querySelectorAll("ellipse").forEach((el) => {
        if (el === body || el === bodyBottom || el.classList.contains("canvas-element__status")) return;
        if (el.getAttribute("fill") === "none") {
          el.setAttribute("cx", x + width / 2);
          el.setAttribute("cy", y + height - 15);
          el.setAttribute("rx", width / 2);
        }
      });

      // Hit rect
      const hitRect = group.querySelector(".canvas-element__hit");
      if (hitRect) {
        hitRect.setAttribute("width", width);
        hitRect.setAttribute("height", height);
      }
    }

    // --- Reposition shared elements ---

    // Label
    const label = group.querySelector(".canvas-element__label");
    if (label) {
      label.setAttribute("x", x + width / 2);
      label.setAttribute("y", y + height - 16);
    }

    // Resize handle
    const handle = group.querySelector(".canvas-element__handle");
    if (handle) {
      handle.setAttribute("x", x + width - 10);
      handle.setAttribute("y", y + height - 10);
    }

    // Status circle (top-right corner)
    const status = group.querySelector(".canvas-element__status");
    if (status) {
      status.setAttribute("cx", x + width - 8);
    }

    // Icon (transform-based, positioned relative to element center)
    const icon = group.querySelector(".canvas-element__icon");
    if (icon) {
      // Save original icon transform in this.dragging (survives DOM patches)
      if (!this.dragging._iconOrig) {
        const t = icon.getAttribute("transform");
        if (t) {
          const m = t.match(/translate\(\s*([^,)]+)[,\s]+([^)]+)\)(.*)/);
          if (m) {
            this.dragging._iconOrig = {
              tx: parseFloat(m[1]),
              ty: parseFloat(m[2]),
              rest: m[3] || "",
            };
          }
        }
      }
      if (this.dragging._iconOrig) {
        const orig = this.dragging._iconOrig;
        // Shift icon center by half the size delta
        const dCx = (width - this.dragging.origWidth) / 2;
        const dCy = (height - this.dragging.origHeight) / 2;
        icon.setAttribute(
          "transform",
          `translate(${orig.tx + dCx}, ${orig.ty + dCy})${orig.rest}`,
        );
      }
    }
  },
};

export default CanvasHook;
