// Optional helper for the day page: select all / none, per-host toggles and a
// running total. The page works without it (every box can be ticked by hand
// and "Download selected" submits an ordinary form).
(function () {
  var form = document.getElementById('zipform');
  if (!form) return;
  var boxes = [].slice.call(form.querySelectorAll('input[name=f]'));
  var out = document.getElementById('zipcount');

  [].forEach.call(document.querySelectorAll('.js-only'), function (el) { el.hidden = false; });

  function fmt(n) {
    var u = ['B', 'KiB', 'MiB', 'GiB', 'TiB'], i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (i === 0 ? n : n.toFixed(n >= 100 ? 0 : 1)) + ' ' + u[i];
  }

  function update() {
    var count = 0, bytes = 0;
    boxes.forEach(function (b) {
      if (b.checked) { count++; bytes += Number(b.getAttribute('data-bytes')) || 0; }
    });
    if (out) out.textContent = count + ' selected, ' + fmt(bytes) + ' before compression';
    [].forEach.call(form.querySelectorAll('section[data-host]'), function (sec) {
      var t = sec.querySelector('.host-toggle');
      if (!t) return;
      var own = [].slice.call(sec.querySelectorAll('input[name=f]'));
      var on = own.filter(function (b) { return b.checked; }).length;
      t.checked = own.length > 0 && on === own.length;
      t.indeterminate = on > 0 && on < own.length;
    });
  }

  form.addEventListener('change', function (e) {
    var t = e.target;
    if (t.classList.contains('host-toggle')) {
      var sec = t.closest('section');
      [].forEach.call(sec.querySelectorAll('input[name=f]'), function (b) { b.checked = t.checked; });
    }
    update();
  });
  form.addEventListener('click', function (e) {
    var act = e.target.getAttribute && e.target.getAttribute('data-act');
    if (!act) return;
    boxes.forEach(function (b) { b.checked = act === 'all'; });
    update();
  });
  update();
})();
