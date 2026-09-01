/* Substrate: the bar that ties the four surfaces together.
 *
 * Before this, the pages did not know about each other. There was one link in
 * the whole app, and the only place the addresses ever appeared was the
 * Terminal window that started the servers. If you did not already know a page
 * existed, you could not reach it.
 *
 * It also tells the truth about the engine: whether the store is answering,
 * and whether the runner is actually picking work up. When the store is down
 * it says what to do about it, in words that do not assume anyone is sitting
 * next to you.
 *
 * Include with:  <script src="../_nav.js"></script>
 */
(function () {
  var STORE = 'http://localhost:8040';
  var PAGES = [
    ['Canvas',    '../canvas/canvas.html'],
    ['Live tree', '../live-tree/live-tree.html'],
    ['Negotiate', '../negotiate/negotiate.html'],
    ['Gates',     '../gates/gates.html']
  ];
  var here = location.pathname;

  var css = document.createElement('style');
  css.textContent = [
    '#sub-nav{position:fixed;top:0;left:0;right:0;z-index:40;display:flex;',
    'align-items:center;gap:2px;padding:7px 14px;background:var(--bg);',
    'border-bottom:.5px solid var(--bd-2);font-size:11px;',
    'font-family:-apple-system,BlinkMacSystemFont,sans-serif;flex-wrap:wrap;}',
    '#sub-nav a{color:var(--text-3);text-decoration:none;padding:5px 11px;',
    'border-radius:20px;min-height:30px;display:inline-flex;align-items:center;}',
    '#sub-nav a:hover{color:var(--text-1);background:var(--fill-hover);}',
    '#sub-nav a.on{color:var(--text-1);background:var(--fill-hover);}',
    '#sub-nav .grow{flex:1;}',
    '#sub-engine{display:flex;align-items:center;gap:7px;color:var(--text-3);}',
    '#sub-engine b{font-weight:500;color:var(--text-2);}',
    '#sub-beacon{width:6px;height:6px;border-radius:50%;background:var(--ok,#34C759);flex:none;}',
    '#sub-beacon.off{background:var(--err,#FF453A);}',
    '#sub-down{position:fixed;inset:0;z-index:60;background:var(--bg);',
    'display:none;align-items:center;justify-content:center;padding:28px;',
    'font-family:-apple-system,BlinkMacSystemFont,sans-serif;}',
    '#sub-down .card{max-width:440px;}',
    '#sub-down h2{font-size:16px;font-weight:600;color:var(--text-1);margin:0 0 12px;}',
    '#sub-down p{font-size:12.5px;line-height:1.75;color:var(--text-2);margin:0 0 12px;}',
    '#sub-down code{font-size:12px;color:var(--text-1);background:var(--fill-hover);',
    'padding:2px 6px;border-radius:5px;}',
    'body:not([data-nav="overlay"]){padding-top:44px;}'
  ].join('');
  document.head.appendChild(css);

  var nav = document.createElement('nav');
  nav.id = 'sub-nav';
  nav.innerHTML =
    PAGES.map(function (p) {
      var on = here.indexOf(p[1].replace('../', '')) > -1 ? ' class="on"' : '';
      return '<a href="' + p[1] + '"' + on + '>' + p[0] + '</a>';
    }).join('') +
    '<span class="grow"></span>' +
    '<span id="sub-engine"><span id="sub-beacon"></span><span id="sub-engine-text">checking</span></span>';
  document.body.appendChild(nav);

  var down = document.createElement('div');
  down.id = 'sub-down';
  down.innerHTML =
    '<div class="card">' +
    '<h2>The Substrate is not running</h2>' +
    '<p>The pages are here, but the part that holds your goals is not answering. ' +
    'Nothing is lost: every goal is saved on disk.</p>' +
    '<p>To start it again: close the Terminal window called ' +
    '<code>Open Substrate</code> if one is open, then double-click ' +
    '<code>Open Substrate.command</code> in the substrate folder. ' +
    'Wait until it says <b>the store: running</b>, then come back to this page.</p>' +
    '<p>This page will notice by itself the moment it is back.</p>' +
    '</div>';
  document.body.appendChild(down);

  function paint(ok, text) {
    document.getElementById('sub-beacon').className = ok ? '' : 'off';
    document.getElementById('sub-engine-text').innerHTML = text;
    down.style.display = ok ? 'none' : 'flex';
  }

  function check() {
    fetch(STORE + '/status')
      .then(function (r) { return r.json(); })
      .then(function (s) {
        var bits = [];
        if (s.thinking && s.thinking.length) {
          bits.push('<b>thinking</b> about a new goal');
        }
        if (s.runner && s.runner.on) {
          bits.push(s.runner.task
            ? '<b>working:</b> ' + s.runner.note
            : '<b>runner on</b> &middot; ' + s.runner.note);
        } else {
          bits.push('runner off');
        }
        paint(true, bits.join(' &middot; '));
      })
      .catch(function () { paint(false, 'not running'); });
  }

  check();
  setInterval(check, 3000);
})();
