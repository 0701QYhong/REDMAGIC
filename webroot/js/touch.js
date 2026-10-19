/* REDMAGIC v3.0.2 —— 触控页：13 项参数全部下拉选择，不接受手填
   数据流是单向的：
     快照 touch_vals（英文短名=值;…）→ 回填表单（dirty 时跳过）→ 用户改 → dirty=1
     → 点「应用」：逐项发 touch_param 存记忆，再发 touch_apply 写节点 → dirty=0
   未连接服务（拿不到快照）时表单只存 localStorage，不假装写成功了。 */
(function (g) {
  'use strict';
  var t = g.t;
  var C = null;   // CARDS，init 之后再取

  /* 与 lib/touch_table.txt 顺序严格一致；key 与后端 touch_key() 映射一致 */
  /* opts 是下拉里的可选值；bin=1 的项显示「关/开」，其余直接显示数值。
     当前值不在列表里时会在回填阶段补一个同名选项，保证出厂值不会丢。 */
  var ITEMS = [
    { key: 'game',       cn: '游戏模式',   opts: ['0', '1'], bin: 1 },
    { key: 'follow',     cn: '跟手速度',   opts: ['0', '1', '2', '3', '4'] },
    { key: 'stability',  cn: '稳定程度',   opts: ['0', '1', '2'] },
    { key: 'sensibility',cn: '灵敏程度',   opts: ['0', '1', '2', '3', '4'] },
    { key: 'report',     cn: '上报频率',   opts: ['0', '1', '2', '3', '4'] },
    { key: 'edge_deb',   cn: '边缘防抖',   opts: ['0', '1'], bin: 1 },
    { key: 'edge_px',    cn: '防抖像素',   opts: ['0', '1', '5', '10', '15', '20', '30', '50'] },
    { key: 'edge_ms',    cn: '防抖时间',   opts: ['0', '40', '80', '100', '150', '200', '300', '500', '800'] },
    { key: 'click_tol',  cn: '点击容错',   opts: ['0', '5', '10', '15', '20', '30', '50'] },
    { key: 'long_on',    cn: '长按识别',   opts: ['0', '1'], bin: 1 },
    { key: 'long_ms',    cn: '长按时长',   opts: ['0', '100', '200', '300', '400', '500', '600', '800', '1000'] },
    { key: 'long_range', cn: '长按范围',   opts: ['0,0,0,0', '5,5,10,10', '10,10,20,20', '20,20,20,20', '20,20,30,30', '30,30,40,40'] },
    { key: 'edge_anti',  cn: '边缘防误触', opts: ['0', '1', '2', '3', '4', '5'] }
  ];

  var PRESETS = {
    official_gaming: {
      game: '1', follow: '4', stability: '0', sensibility: '4', report: '4',
      edge_deb: '0', edge_px: '0', edge_ms: '0', click_tol: '0',
      long_on: '0', long_ms: '0', long_range: '0,0,0,0', edge_anti: '0'
    },
    official_daily: {
      game: '0', follow: '2', stability: '2', sensibility: '2', report: '2',
      edge_deb: '1', edge_px: '10', edge_ms: '100', click_tol: '10',
      long_on: '1', long_ms: '500', long_range: '10,10,20,20', edge_anti: '5'
    }
  };

  var dirty = false;
  var formBuilt = false;
  var curPreset = 'official_gaming';

  function inputs() {
    var box = document.getElementById('touchForm');
    if (!box) return [];
    return box.querySelectorAll('select');
  }

  function build() {
    var box = document.getElementById('touchForm');
    if (!box || formBuilt) return;
    var html = '';
    for (var i = 0; i < ITEMS.length; i++) {
      var it = ITEMS[i], opt = '';
      for (var j = 0; j < it.opts.length; j++) {
        var v = it.opts[j], lb = v;
        if (it.bin) lb = v === '0' ? t('off_s') : t('on');
        opt += '<option value="' + v + '"' + (it.bin ? ' data-i18n="' + (v === '0' ? 'off_s' : 'on') + '"' : '') + '>' + lb + '</option>';
      }
      html += '<div class="it"><label class="nm" for="tp_' + it.key + '">' + t('touch_item_' + i) + '</label>' +
              '<select id="tp_' + it.key + '" data-k="' + it.key + '">' + opt + '</select></div>';
    }
    box.innerHTML = html;
    var is = inputs();
    for (var j = 0; j < is.length; j++) {
      is[j].addEventListener('change', function () {
        dirty = true;
        markDirty();
      });
    }
    formBuilt = true;
  }

  function markDirty() {
    C.show('touchDirty', dirty);
  }

  function readForm() {
    var o = {}, is = inputs();
    for (var i = 0; i < is.length; i++) {
      var v = String(is[i].value).replace(/\s+/g, '').replace(/，/g, ',');
      if (v === '' || !/^[0-9]+(,[0-9]+)*$/.test(v)) return null;
      o[is[i].getAttribute('data-k')] = v;
    }
    return o;
  }

  function fill(vals) {
    var is = inputs();
    for (var i = 0; i < is.length; i++) {
      var k = is[i].getAttribute('data-k');
      if (!vals || vals[k] == null || document.activeElement === is[i]) continue;
      var v = vals[k], has = false;
      for (var j = 0; j < is[i].options.length; j++) {
        if (is[i].options[j].value === v) { has = true; break; }
      }
      if (!has) {
        var o = document.createElement('option');
        o.value = v;
        o.textContent = v;
        is[i].appendChild(o);
      }
      is[i].value = v;
    }
  }

  function parseVals(s) {
    var o = {};
    if (!s) return o;
    var parts = String(s).split(';');
    for (var i = 0; i < parts.length; i++) {
      var e = parts[i].indexOf('=');
      if (e > 0) o[parts[i].slice(0, e)] = parts[i].slice(e + 1);
    }
    return o;
  }

  function applyPreset(name) {
    var p = PRESETS[name];
    if (!p) return;
    fill(p);
    curPreset = name;
    dirty = true;
    markDirty();
  }

  function presetOf(vals) {
    for (var name in PRESETS) {
      if (!PRESETS.hasOwnProperty(name)) continue;
      var p = PRESETS[name], same = true;
      for (var k in p) {
        if (!p.hasOwnProperty(k)) continue;
        if ((vals[k] || '') !== p[k]) { same = false; break; }
      }
      if (same) return name;
    }
    return '';
  }

  /* 逐项发命令；全部发完才发 touch_apply 写节点 */
  function applyAll() {
    var vals = readForm();
    if (!vals) { C.toast(t('toast_bad'), 'bad'); return; }
    var keys = [];
    for (var k in vals) if (vals.hasOwnProperty(k)) keys.push(k);
    var i = 0, chain = Promise.resolve();
    keys.forEach(function (k) {
      var cn = '';
      for (var j = 0; j < ITEMS.length; j++) if (ITEMS[j].key === k) cn = ITEMS[j].cn;
      var kv = cn ? (cn + '=' + vals[k]) : '';
      if (!kv) return;
      chain = chain.then(function () { return g.API.send('touch_param', kv); });
      i++;
    });
    if (i === 0) { C.toast(t('toast_bad'), 'bad'); return; }
    chain.then(function () {
      return g.API.send('touch_apply', '');
    }).then(function () {
      dirty = false;
      markDirty();
      C.toast(t('toast_applied'), 'ok');
      g.API.refreshSoon();
    }, function (e) {
      C.toastErr(e);
      g.API.refreshSoon();
    });
  }

  /* 「还原」= 回到当前生效值（快照里的 touch_vals），不是回到出厂 */
  function revert() {
    var d = g.API.data();
    if (d) fill(parseVals(d.touch_vals));
    var p = presetOf(parseVals(d ? d.touch_vals : ''));
    if (p) curPreset = p;
    C.paintSeg('touchPresetSeg', p || curPreset);
    dirty = false;
    markDirty();
  }

  function render(d) {
    if (!formBuilt) return;
    var on = d.touch_on === '1';
    var miss = parseInt(d.touch_missing, 10) || 0;
    var avail = miss === 0;
    C.dot('touchDot', !avail ? 'warn' : on ? 'on' : '');
    C.setVal('touchOn', on);

    var s;
    if (!avail) s = t('t_disabled') + ' · ' + miss + '/6';
    else if (!on) s = t('t_idle');
    else if (d.touch_mode === 'preset') s = t('t_touch_ok');
    else s = t('t_touch_bad');
    C.setText('touchStateDesc', s);

    if (!dirty) {
      var vals = parseVals(d.touch_vals);
      fill(vals);
      var p = presetOf(vals);
      if (p) curPreset = p;
      C.paintSeg('touchPresetSeg', p || '');
    }
  }

  function init() {
    C = g.CARDS;
    build();
    markDirty();
    C.bindSwitch('touchOn', 'touch_on');
    document.getElementById('touchPresetSeg').addEventListener('click', function (ev) {
      var b = ev.target;
      var box = document.getElementById('touchPresetSeg');
      while (b && b !== box && b.tagName !== 'BUTTON') b = b.parentNode;
      if (!b || b === box) return;
      var v = b.getAttribute('data-v');
      if (!v) return;
      applyPreset(v);
      C.paintSeg('touchPresetSeg', v);
      C.toast(t('toast_saved'), 'ok');
    });
    document.getElementById('touchApply').addEventListener('click', applyAll);
    document.getElementById('touchReset').addEventListener('click', revert);
  }

  g.TOUCH = { init: init, render: render };
})(window);
