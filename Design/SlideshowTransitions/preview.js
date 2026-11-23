(() => {
  const { catalog, choose, sample } = PhotoEarthTransitions;
  const $ = id => document.getElementById(id);
  const screen = $('screen');
  const ctx = screen.getContext('2d');
  const W = screen.width, H = screen.height;
  const media = new Map();
  const motion = matchMedia('(prefers-reduced-motion: reduce)');
  $('reduced').checked = motion.matches;

  function buffer() {
    const canvas = document.createElement('canvas');
    canvas.width = W; canvas.height = H;
    return canvas;
  }
  const overlay = buffer();
  const overlayCtx = overlay.getContext('2d');

  function page(photos, minute, favorite = false) {
    return { photos: [].concat(photos), minute, favorite, visit: 1, day: 1 };
  }
  const pages = [
    page('Paris', 0), page('Istanbul', 5), page('Banff', 10, true),
    page('Tokyo', 14), page('Rio', 20), page('p1', 26), page('p2', 31),
    page('Reykjavik', 35), page('CapeTown', 90),
    page(['p1','p2','p3'], 95), page(['s4','s5','s6'], 100),
    page(['p1','p2','p3'], 105), page('Sydney', 110),
    page('Rio', 114), page('Istanbul', 118), page('Paris', 122), page('Sydney', 126)
  ];
  const examples = { dissolve: [0,1], settle: [1,2], reveal: [7,8], backdrop: [4,5], stagger: [9,10],
                     panoramaGlide: [15,16], focusPullback: [1,2], centerOpen: [8,9] };
  const sequence = [];
  let current = null, index = 0, progress = 1, duration = 720;
  let effect = 'dissolve', mode = 'example', playing = false, job = 0, last = null, held = 0;
  let sequenceStarted = false, paused = false;

  async function loadPhoto(id) {
    const portrait = /^[ps]\d$/.test(id);
    const image = new Image();
    image.src = portrait ? '../../PhotoEarth/Preview%20Content/Collage' + id[1] + '.jpg'
                         : '../../PhotoEarth/Resources/Demo' + id + '.jpg';
    await image.decode();
    // Three matched 9:16 sample prints for demonstrating a second identical grid.
    if (id.startsWith('s')) {
      const print = document.createElement('canvas');
      print.width = 540; print.height = 960;
      print.getContext('2d').drawImage(image, (image.width - 540) / 2, 0, 540, 960, 0, 0, 540, 960);
      media.set(id, print);
    } else { media.set(id, image); }
  }

  function makePage(model) {
    const photos = model.photos.map(id => media.get(id));
    const gap = W / 320;
    const h = Math.min(H, (W - gap * (photos.length - 1)) / model.ratios.reduce((a,b) => a + b));
    const width = model.ratios.reduce((a,b) => a + b * h, gap * (photos.length - 1));
    let x = (W - width) / 2;
    const bg = buffer(), fg = buffer(), full = buffer();
    const b = bg.getContext('2d'), f = fg.getContext('2d');
    b.fillStyle = '#10110f'; b.fillRect(0, 0, W, H);
    if (photos.length === 1) {
      const pic = photos[0], scale = Math.max(W / pic.width, H / pic.height) * 1.2;
      b.filter = 'blur(26px)'; b.globalAlpha = 0.32;
      b.drawImage(pic, (W - pic.width * scale)/2, (H - pic.height * scale)/2, pic.width * scale, pic.height * scale);
    }
    const slots = photos.map((pic, i) => {
      const w = model.ratios[i] * h, y = (H - h)/2;
      f.drawImage(pic, x, y, w, h);
      const rect = [x, y, w, h]; x += w + gap; return rect;
    });
    const c = full.getContext('2d'); c.drawImage(bg,0,0); c.drawImage(fg,0,0);
    return { model, bg, fg, full, slots };
  }

  function paint() {
    if (!current) return;
    const [a, b] = current;
    const frame = sample(effect, progress, b.slots.length, $('reduced').checked);
    ctx.globalAlpha = 1;
    ctx.drawImage(a.full, 0, 0);
    if (progress >= 1) { ctx.drawImage(b.full, 0, 0); }
    else if (progress > 0) {
      if (frame.cells) {
        b.slots.forEach(([x,y,w,h], i) => {
          ctx.globalAlpha = frame.cells[i]; ctx.drawImage(b.full, x,y,w,h, x,y,w,h);
        });
      } else if (frame.glide) {
        ctx.drawImage(a.bg, 0, 0);
        ctx.drawImage(a.fg, frame.glide.oldX * W, 0);
        overlayCtx.drawImage(b.bg, 0, 0);
        overlayCtx.drawImage(b.fg, frame.glide.nextX * W, 0);
        ctx.globalAlpha = frame.blend;
        ctx.drawImage(overlay, 0, 0);
      } else if (frame.openWidth > 0) {
        const c = overlayCtx, width = frame.openWidth * W;
        const gradient = c.createLinearGradient((W-width)/2, 0, (W+width)/2, 0);
        gradient.addColorStop(0, 'transparent'); gradient.addColorStop(0.025, 'white');
        gradient.addColorStop(0.975, 'white'); gradient.addColorStop(1, 'transparent');
        c.drawImage(b.full, 0, 0); c.globalCompositeOperation = 'destination-in';
        c.fillStyle = gradient; c.fillRect(0, 0, W, H); c.globalCompositeOperation = 'source-over';
        ctx.drawImage(overlay, 0, 0);
      } else if (frame.mask) {
        const { edge, feather } = frame.mask, c = overlayCtx;
        c.drawImage(b.full, 0, 0); c.globalCompositeOperation = 'destination-in';
        const g = c.createLinearGradient((edge-feather)*W,0,edge*W,0);
        g.addColorStop(0,'white'); g.addColorStop(1,'transparent');
        c.fillStyle = g; c.fillRect(0,0,W,H); c.globalCompositeOperation = 'source-over';
        ctx.drawImage(overlay, 0, 0);
      } else if (effect === 'backdrop' && !$('reduced').checked) {
        ctx.drawImage(a.bg, 0, 0); ctx.globalAlpha = frame.background; ctx.drawImage(b.bg, 0, 0);
        // Blend the two transparent foregrounds in premultiplied color before compositing onto the backdrop.
        const c = overlayCtx; c.clearRect(0,0,W,H);
        c.globalAlpha = 1 - frame.foreground; c.drawImage(a.fg,0,0);
        c.globalCompositeOperation = 'lighter'; c.globalAlpha = frame.foreground; c.drawImage(b.fg,0,0);
        c.globalAlpha = 1; c.globalCompositeOperation = 'source-over';
        ctx.globalAlpha = 1; ctx.drawImage(overlay,0,0);
      } else {
        ctx.globalAlpha = frame.blend;
        if (frame.scale === 1) { ctx.drawImage(b.full, 0, 0); }
        else {
          const s = frame.scale;
          overlayCtx.drawImage(b.bg,0,0);
          overlayCtx.drawImage(b.fg,W*(1-s)/2,H*(1-s)/2,W*s,H*s);
          ctx.drawImage(overlay,0,0);
        }
      }
    }
    ctx.globalAlpha = 1;
    $('progress').value = Math.round(progress * 1000);
  }

  function display(a, b, id, manual = false) {
    // A second remote press starts where the previous dissolve actually reached.
    let interruptedFrame;
    if (manual && current && progress < 1) {
      interruptedFrame = buffer();
      interruptedFrame.getContext('2d').drawImage(screen, 0, 0);
    }
    const cachedPage = model => current?.find(layer => layer.model === model) ?? makePage(model);
    current = [cachedPage(pages[a]), cachedPage(pages[b])];
    if (interruptedFrame) current[0] = { full: interruptedFrame };
    effect = id; index = b; held = 0; progress = 0;
    duration = manual ? 160 : $('reduced').checked ? 200 : catalog[id].ms;
    const label = $('reduced').checked ? '短叠化' : manual ? '手动短叠化' : catalog[id].name;
    $('now').textContent = (mode === 'sequence' ? '连播 · ' : '') + label;
    $('timing').textContent = (mode === 'sequence' ? b + ' / ' + (pages.length-1) + '　·　' : '') + duration + ' ms';
    $('desc').textContent = $('reduced').checked ? '减少动态效果已开启，所有换页都使用短叠化。' : catalog[id].description;
    document.querySelectorAll('[data-effect]').forEach(btn => btn.setAttribute('aria-pressed', btn.dataset.effect === id));
    paint();
  }

  function stop() {
    cancelAnimationFrame(job); playing = false; last = null;
  }
  function controls() {
    $('sequence').textContent = mode === 'sequence' && playing ? '暂停放映' : paused && mode === 'sequence' ? '继续放映' : '连续放映';
  }
  function start() {
    stop(); playing = true; paused = false; controls();
    function tick(time) {
      const delta = last === null ? 0 : time - last; last = time;
      if (progress < 1) { progress = Math.min(1, progress + delta / duration); paint(); }
      else if (mode === 'sequence') {
        held += delta;
        const dwell = [0,3600,5000,6500][pages[index].photos.length];
        if (held >= dwell) {
          if (index + 1 < pages.length) display(index, index+1, sequence[index+1]);
          else { stop(); sequenceStarted = false; controls(); return; }
        }
      } else { stop(); controls(); return; }
      job = requestAnimationFrame(tick);
    }
    job = requestAnimationFrame(tick);
  }
  function example(id) {
    mode = 'example'; sequenceStarted = false; paused = false;
    display(...examples[id], id); start();
  }

  async function init() {
    await Promise.all([...new Set(pages.flatMap(p => p.photos))].map(loadPhoto));
    pages.forEach(p => { p.ratios = p.photos.map(id => media.get(id).width/media.get(id).height); });
    sequence.push('dissolve');
    for (let i = 1; i < pages.length; i++) sequence.push(choose(pages[i-1], pages[i], sequence.slice(1)));
    for (const [id, spec] of Object.entries(catalog)) {
      const button = document.createElement('button'); button.dataset.effect = id;
      const title = document.createElement('span'); title.textContent = spec.name;
      const ms = document.createElement('small'); ms.textContent = spec.ms + ' ms';
      button.append(title, ms); button.onclick = () => example(id);
      $('library').insertBefore(button, $('desc'));
    }
    $('sequence').onclick = () => {
      if (mode === 'sequence' && playing) { stop(); paused = true; controls(); return; }
      if (!sequenceStarted) { mode = 'sequence'; sequenceStarted = true; display(0,1,sequence[1]); }
      start();
    };
    $('replay').onclick = () => { progress = 0; held = 0; start(); };
    $('next').onclick = () => {
      const next = (index+1) % pages.length; mode = 'manual'; sequenceStarted = false;
      display(index, next, 'dissolve', true); start();
    };
    $('progress').oninput = () => {
      stop(); paused = true; held = 0; progress = Number($('progress').value)/1000; paint(); controls();
    };
    $('reduced').onchange = () => {
      if (mode === 'example') { example(effect); return; }
      const wasPlaying = playing, from = index === 0 ? pages.length-1 : index-1;
      stop(); display(from,index,effect,mode === 'manual');
      if (wasPlaying) start(); else { progress = 1; paint(); controls(); }
    };
    motion.onchange = e => { $('reduced').checked = e.matches; $('reduced').onchange(); };
    document.addEventListener('visibilitychange', () => {
      if (document.hidden && playing) { stop(); paused = true; controls(); }
    });
    example('dissolve');
  }
  init().catch(() => { $('now').textContent = '样片读取失败，请从工程 Design/SlideshowTransitions 目录打开。'; });
})();
