// calfNXT macOS — CSS viewport reporting.
//
// Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
//
// The native side owns sizing (the editor tracks the host NSView), so there
// is no viewport to report. If the WebView never lays out (0×0 — the failure
// mode behind the host-fill workaround), post one diagnostic the native side
// writes to /tmp/calfnxt-ui.log.
import { postToHost } from './bridge';

export type DesignSize = { width: number; height: number };

export function reportCssViewportOnce(_design?: DesignSize): void {
  window.requestAnimationFrame(() => {
    window.requestAnimationFrame(() => {
      const w = Math.round(window.innerWidth);
      const h = Math.round(window.innerHeight);
      if (w < 1 || h < 1) postToHost({ t: '_diag', msg: 'viewport-zero', w, h });
    });
  });
}
