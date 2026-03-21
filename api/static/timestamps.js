// Smart timestamps: anchor + delta pattern.
// Events close together show deltas (+120ms), others show relative time (3m ago).
// Hover shows full absolute time with ms precision.

(function () {
  const ANCHOR_GAP_MS = 2000; // gap threshold for new anchor
  const REFRESH_MS = 15000;   // how often to update relative times

  function parse(iso) {
    return new Date(iso).getTime();
  }

  function absLabel(ms) {
    var d = new Date(ms);
    var pad2 = function (n) { return n < 10 ? '0' + n : '' + n; };
    var pad3 = function (n) { return n < 10 ? '00' + n : n < 100 ? '0' + n : '' + n; };
    var months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return months[d.getMonth()] + ' ' + pad2(d.getDate()) + ' ' +
      pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' +
      pad2(d.getSeconds()) + '.' + pad3(d.getMilliseconds());
  }

  function relativeLabel(ms) {
    var diff = Date.now() - ms;
    if (diff < 0) return 'just now';
    var s = Math.floor(diff / 1000);
    if (s < 60) return s + 's ago';
    var m = Math.floor(s / 60);
    if (m < 60) return m + 'm ago';
    var h = Math.floor(m / 60);
    if (h < 24) return h + 'h ago';
    var d = Math.floor(h / 24);
    if (d < 7) return d + 'd ago';
    return absLabel(ms).slice(0, 6); // "Mar 21"
  }

  function deltaLabel(ms) {
    if (ms < 1000) return '+' + Math.round(ms) + 'ms';
    if (ms < 10000) return '+' + (ms / 1000).toFixed(1) + 's';
    return '+' + Math.round(ms / 1000) + 's';
  }

  function render() {
    var cells = document.querySelectorAll('td[data-ts]');
    if (!cells.length) return;

    var anchorMs = null;

    // Events are displayed newest-first (DESC), so iterate top-to-bottom.
    // But "anchor" logic works in chronological order: an anchor is the first
    // event in a cluster. Since rows are newest-first, the anchor is the LAST
    // event in a cluster as we scan down. We do two passes:
    // 1. Collect timestamps and determine anchors (bottom-up = chronological).
    // 2. Render top-down.

    var items = [];
    for (var i = 0; i < cells.length; i++) {
      var ts = cells[i].getAttribute('data-ts');
      items.push({ cell: cells[i], ms: parse(ts) });
    }

    // Walk chronologically (bottom to top of the displayed list).
    anchorMs = null;
    for (var i = items.length - 1; i >= 0; i--) {
      var ms = items[i].ms;
      if (anchorMs === null || Math.abs(ms - anchorMs) >= ANCHOR_GAP_MS) {
        items[i].anchor = true;
        anchorMs = ms;
        items[i].anchorMs = ms;
      } else {
        items[i].anchor = false;
        items[i].anchorMs = anchorMs;
        items[i].delta = ms - anchorMs;
      }
    }

    for (var i = 0; i < items.length; i++) {
      var it = items[i];
      var abs = absLabel(it.ms);
      it.cell.title = abs;

      if (it.anchor) {
        it.cell.textContent = relativeLabel(it.ms);
        it.cell.classList.remove('ts-delta');
      } else {
        it.cell.textContent = deltaLabel(it.delta);
        it.cell.classList.add('ts-delta');
      }
    }
  }

  // Initial render.
  render();

  // Re-render periodically to keep relative times fresh.
  setInterval(render, REFRESH_MS);

  // Re-render after HTMX swaps (filter changes, pagination, SSE).
  document.body.addEventListener('htmx:afterSwap', function () {
    // Small delay to ensure DOM is settled.
    setTimeout(render, 10);
  });
  document.body.addEventListener('htmx:sseMessage', function () {
    setTimeout(render, 10);
  });
})();
