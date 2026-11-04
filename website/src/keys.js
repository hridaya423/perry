// Must match the app's defaults in perry/App/Shortcuts/Gesture.swift.

const TAP = 0.3, DOUBLE = 0.42, HOLD = 0.22;

export function createKeys({ ask, wake, talk }) {
  let downAt = -1, lastTap = -10, dirty = false, holdTimer = 0, talking = false;
  const now = () => performance.now() / 1000;
  const typing = () => /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName) || document.activeElement?.isContentEditable;

  function stopTalk() {
    clearTimeout(holdTimer);
    if (talking) { talking = false; talk(false); }
  }

  addEventListener('keydown', (e) => {
    if (e.repeat) return;
    if (e.code === 'KeyP' && e.altKey && e.metaKey && !e.ctrlKey && !e.shiftKey) {
      e.preventDefault();
      wake();
      return;
    }
    const mod = e.key === 'Control' || e.key === 'Alt';
    if (!mod) { dirty = true; stopTalk(); return; }
    if (e.key === 'Control' && !e.altKey && !e.metaKey && !e.shiftKey) { downAt = now(); dirty = false; }
    if (e.ctrlKey && e.altKey && !e.metaKey && !e.shiftKey && !typing()) {
      dirty = true;
      clearTimeout(holdTimer);
      holdTimer = setTimeout(() => { talking = true; talk(true); }, HOLD * 1000);
    }
  });

  addEventListener('keyup', (e) => {
    if (e.key === 'Control' || e.key === 'Alt') stopTalk();
    if (e.key !== 'Control') return;
    const t = now();
    const tap = !dirty && downAt > 0 && t - downAt < TAP;
    downAt = -1;
    if (!tap || typing()) return;
    if (t - lastTap < DOUBLE) { lastTap = -10; ask(); } else lastTap = t;
  });

  addEventListener('blur', () => { downAt = -1; stopTalk(); });
}
