// Page descriptors supply the final layout, not the orientation of the first asset.
window.PhotoEarthTransitions = (() => {
  const catalog = {
    dissolve: { name: '柔和叠化', ms: 720, description: '上一页稳住，新画面逐渐接过来。适合连续观看，也是整场的基本节奏。' },
    settle: { name: '轻推入场', ms: 780, startScale: 0.982, description: '新照片从略小的位置向前靠近，停在完整构图上。适合一张值得多看一眼的静态照片。' },
    reveal: { name: '柔边揭幕', ms: 820, feather: 0.50, description: '一道很宽的柔边从左向右带出新景，两张照片都留在原位。适合同一站里隔了一段时间的新场景。' },
    backdrop: { name: '背景先行', ms: 800, backgroundEnd: 0.65, photoStart: 0.20, description: '背景先换成下一张的色调，前景照片稍后叠入。适合横图转竖图或竖图转横图。' },
    stagger: { name: '拼图错拍', ms: 820, offsetMs: 85, description: '相邻两页的格线对齐时，从左到右依次换照片。格线和照片位置固定，每格只做叠化。' }
  };
  const smooth = t => t * t * (3 - 2 * t);
  const clamp = t => Math.min(1, Math.max(0, t));
  function sameGrid(a, b) {
    return a.ratios.length > 1 && a.ratios.length === b.ratios.length
      && a.ratios.every((r, i) => Math.abs(r - b.ratios[i]) < 0.001);
  }
  function choose(a, b, recent, { reduced = false, manual = false } = {}) {
    if (reduced || manual || a.dynamic || b.dynamic || a.visit !== b.visit || a.day !== b.day) return 'dissolve';
    // At least two ordinary transitions between accents.
    if (recent.slice(-2).some(id => id !== 'dissolve')) return 'dissolve';
    if (sameGrid(a, b)) return 'stagger';
    if (a.ratios.length !== 1 || b.ratios.length !== 1) return 'dissolve';
    if ((a.ratios[0] < 1) !== (b.ratios[0] < 1)) return 'backdrop';
    if (b.minute - a.minute >= 45) return 'reveal';
    return b.favorite && !recent.slice(-6).includes('settle') ? 'settle' : 'dissolve';
  }
  // Composable timing channels, consumed by the renderer with one progress clock.
  function sample(id, progress, columns = 1, reduced = false) {
    const effect = catalog[id];
    const p = clamp(progress);
    const blend = smooth(p);
    const frame = { blend, scale: 1, background: blend, foreground: blend, mask: null, cells: null };
    if (reduced) return frame;
    switch (id) {
      case 'settle':
        frame.scale = effect.startScale + (1 - effect.startScale) * (1 - Math.pow(1 - p, 3));
        break;
      case 'reveal':
        frame.mask = { edge: (1 + effect.feather) * blend, feather: effect.feather };
        break;
      case 'backdrop':
        frame.background = smooth(clamp(p / effect.backgroundEnd));
        frame.foreground = smooth(clamp((p - effect.photoStart) / (1 - effect.photoStart)));
        break;
      case 'stagger': {
        const span = effect.ms - (columns - 1) * effect.offsetMs;
        frame.cells = Array.from({ length: columns }, (_, i) => smooth(clamp((p * effect.ms - i * effect.offsetMs) / span)));
        break;
      }
    }
    return frame;
  }
  return { catalog, choose, sample, sameGrid };
})();
