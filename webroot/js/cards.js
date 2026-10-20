/* REDMAGIC v3.0.5 —— 通用控件 + 六张功能卡：风扇 / 液冷 / 充电 / 温控 / 采样率 / 亮度
   规矩：任何一次点击都只发命令，状态一律等快照回来再渲染（不做乐观更新），
   这样节点写失败、系统开关没开时，界面显示的和真机一致。 */
(function (g) {
  'use strict';
  var t = g.t;

  /* ---------------- DOM 小工具 ---------------- */
  function $(id) { return document.getElementById(id); }
  function setText(id, s) { var e = $(id); if (e && e.textContent !== s) e.textContent = s; }
  function setVal(id, v) {
    var e = $(id);
    if (!e) return;
    if (e.type === 'checkbox') { var b = !!v; if (e.checked !== b) e.checked = b; return; }
    if (document.activeElement === e) return;   // 正在拖的滑杆不回写
    if (v == null) return;
    if (e.value !== String(v)) e.value = String(v);
  }
  function show(id, on) { var e = $(id); if (e) e.style.display = on ? '' : 'none'; }
  function dot(id, s) {
    var e = $(id);
    if (!e) return;
    e.className = 'dot' + (s === 'on' ? ' on' : s === 'warn' ? ' warn' : '');
  }

  /* ---------------- 吐司 ---------------- */
  var toastTimer = 0;
  function toast(msg, kind) {
    var e = $('toast');
    if (!e) return;
    e.textContent = msg;
    e.className = 'toast show' + (kind ? ' ' + kind : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { e.className = 'toast'; }, 1900);
  }
  function toastErr(e) { toast((e && e.message) || t('toast_fail'), 'bad'); }

  /* ---------------- 命令 ---------------- */
  var pending = 0;
  function cmd(c, v) {
    pending++;
    return g.API.send(c, v).then(function () {
      g.API.refreshSoon();
      return true;
    }, function (e) {
      toastErr(e);
      g.API.refreshSoon();
      return false;
    }).then(function (r) {
      pending--;
      return r;
    });
  }
  function busy() { return pending > 0; }

  /* ---------------- 开关：勾上才发命令 ---------------- */
  function bindSwitch(id, action) {
    var el = $(id);
    if (!el) return;
    el.addEventListener('change', function () {
      var on = el.checked;
      cmd(action, on ? 'on' : 'off').then(function (ok) {
        if (ok) toast(t(on ? 'toast_on' : 'toast_off'), 'ok');
        else g.API.refreshSoon();
      });
    });
  }

  /* ---------------- 滑杆：松手才发（拖动过程只在本地显示） ---------------- */
  function bindRange(id, labelId, action, suffix) {
    var el = $(id);
    if (!el) return;
    var fmt = function (v) { return String(v) + (suffix || ''); };
    el.addEventListener('input', function () { setText(labelId, fmt(el.value)); });
    el.addEventListener('change', function () {
      var v = parseInt(el.value, 10);
      if (!isFinite(v)) return;
      cmd(action, v).then(function (ok) { if (ok) toast(t('toast_applied'), 'ok'); });
    });
  }

  /* ---------------- 分段按钮：off / auto / custom ---------------- */
  function paintSeg(id, v) {
    var box = $(id);
    if (!box) return;
    var bs = box.getElementsByTagName('button');
    for (var i = 0; i < bs.length; i++) {
      if (bs[i].getAttribute('data-v') === v) bs[i].classList.add('on');
      else bs[i].classList.remove('on');
    }
  }
  function bindSeg(id, pick, label) {
    var box = $(id);
    if (!box) return;
    box.addEventListener('click', function (ev) {
      var b = ev.target;
      while (b && b !== box && b.tagName !== 'BUTTON') b = b.parentNode;
      if (!b || b === box) return;
      var v = b.getAttribute('data-v');
      if (!v) return;
      cmd(pick, v).then(function (ok) {
        if (!ok) return;
        paintSeg(id, v);
        if (label && label.thr) show(label.thr, v === 'custom');
        toast(t('toast_applied'), 'ok');
      });
    });
  }

  /* ---------------- 数字输入 + 应用按钮 ---------------- */
  function bindNum(id, btnId, action, lo, hi, labelId, suffix) {
    var el = $(id), btn = $(btnId);
    if (!el || !btn) return;
    btn.addEventListener('click', function () {
      var v = parseInt(String(el.value).replace(/[^0-9]/g, ''), 10);
      if (!isFinite(v) || v < lo || v > hi) { toast(t('toast_bad'), 'bad'); return; }
      cmd(action, v).then(function (ok) {
        if (ok) { if (labelId) setText(labelId, String(v) + (suffix || '')); toast(t('toast_applied'), 'ok'); }
      });
    });
  }

  /* ---------------- 渲染：快照 -> 界面 ---------------- */
  function num(d, k) { var v = parseInt(d[k], 10); return isFinite(v) ? v : 0; }
  function on(d, k) { return num(d, k) === 1; }

  function renderFan(d) {
    var enabled = on(d, 'fan_on'), sys = on(d, 'fan_enabled'), avail = on(d, 'fan_available');
    var lvl = d.fan_level_saved || '';
    var tmode = d.fan_temp_ctrl === '1' ? (d.fan_temp_mode || 'auto') : 'off';
    var lvNow = d.fan_level;

    dot('fanDot', !avail ? 'warn' : enabled ? (sys ? 'on' : 'warn') : '');
    setVal('fanOn', enabled);
    setVal('fanKeep', on(d, 'fan_keep'));

    var s;
    if (!avail) s = t('t_disabled');
    else if (!enabled) s = t('t_idle');
    else if (!sys) s = t('t_wait');
    else if (lvNow) s = t('t_active') + ' · ' + lvNow + ' / 5';
    else s = t('t_applying');
    setText('fanStateDesc', s);

    if (lvl) {
      setVal('fanLevel', lvl);
      setText('fanLevelVal', lvl + ' / 5');
    } else if (lvNow) {
      setText('fanLevelVal', lvNow + ' / 5');
    }
    $('fanLevel').disabled = !avail;

    paintSeg('fanTempSeg', tmode);
    setVal('fanTempThr', d.fan_temp_thr || 40);
    setText('fanTempThrVal', (d.fan_temp_thr || '40') + ' ' + t('deg'));
    show('fanTempThrWrap', tmode === 'custom');
  }

  function renderPump(d) {
    var enabled = on(d, 'pump_on'), avail = on(d, 'pump_available');
    var lvl = d.pump_level_saved || '';
    var tmode = d.pump_temp_ctrl === '1' ? (d.pump_temp_mode || 'auto') : 'off';
    var lvNow = d.pump_level;

    dot('pumpDot', !avail ? 'warn' : enabled ? 'on' : '');
    setVal('pumpOn', enabled);
    setVal('pumpKeep', on(d, 'pump_keep'));

    var s;
    if (!avail) s = t('t_disabled');
    else if (!enabled) s = t('t_idle');
    else if (lvNow) s = t('t_active') + ' · ' + lvNow + ' / 4';
    else s = t('t_applying');
    setText('pumpStateDesc', s);

    if (lvl) { setVal('pumpLevel', lvl); setText('pumpLevelVal', lvl + ' / 4'); }
    else if (lvNow) { setText('pumpLevelVal', lvNow + ' / 4'); }
    $('pumpLevel').disabled = !avail;

    paintSeg('pumpTempSeg', tmode);
    setVal('pumpTempThr', d.pump_temp_thr || 40);
    setText('pumpTempThrVal', (d.pump_temp_thr || '40') + ' ' + t('deg'));
    show('pumpTempThrWrap', tmode === 'custom');
  }

  function renderCharge(d) {
    var sep = d.cs === '1', armed = on(d, 'charge_on'), cap = num(d, 'battery'), thr = num(d, 'threshold');
    var boost = on(d, 'boost_on'), ready = on(d, 'boost_ready'), thermal = on(d, 'thermal_on');

    dot('chargeDot', sep ? 'on' : armed ? 'warn' : '');
    setVal('chargeOn', armed);
    setVal('chargeThr', thr || 100);
    setText('chargeThrVal', (thr || 100) + ' ' + t('pct'));

    var s;
    if (!armed) s = t('t_split_off');
    else if (sep) s = t('t_split_on');
    else s = t('t_split_wait');
    if (armed) s += ' · ' + cap + t('pct') + ' / ' + thr + t('pct');
    setText('chargeSepDesc', s);

    setVal('boostOn', boost);
    var b;
    if (!thermal) b = t('t_boost_blocked') + ' · ' + t('thermal_title');
    else if (!boost) b = t('t_boost_off');
    else if (ready) b = t('t_boost_on');
    else b = t('t_boost_blocked');
    setText('boostDesc', b);
    setVal('boostThr', d.boost_thr || 42);
    setText('boostThrVal', (d.boost_thr || '42') + ' ' + t('deg'));
    setVal('boostHeat', on(d, 'boost_heat'));
  }

  function renderThermal(d) {
    var want = on(d, 'thermal_on'), eff = on(d, 'thermal_effective');
    dot('thermalDot', eff ? 'on' : want ? 'warn' : '');
    setVal('thermalOn', want);
    setText('thermalDesc', !want ? t('t_thermal_off') : eff ? t('t_thermal_on') : t('t_applying'));
  }

  function renderRate(d) {
    var onx = on(d, 'rate_on'), cur = num(d, 'rate_value'), tgt = num(d, 'rate_target');
    dot('rateDot', onx ? (cur ? 'on' : 'warn') : '');
    setVal('rateOn', onx);
    /* 上限留空 = 自动（取当前值与档位上限的较大者），所以空串要回填，不能保留旧值 */
    setVal('rateMax', d.rate_max || '');
    setText('rateDesc', onx ? (t('t_active') + (tgt ? ' · ' + tgt : '')) : t('t_idle'));
    var e = $('rateCur');
    if (e) e.textContent = cur ? (cur + ' ' + t('t_rate_hz')) : '--';
    if (e) e.className = 'pill' + (onx ? (cur ? ' ok' : ' warn') : '');
  }

  function renderBright(d) {
    var avail = on(d, 'bright_available'), onx = on(d, 'bright_on');
    var cur = num(d, 'bright_cur'), mx = num(d, 'bright_max'), goal = num(d, 'bright_goal');
    dot('brightDot', !avail ? 'warn' : onx ? 'on' : '');
    setVal('brightOn', onx && avail);
    var s;
    if (!avail) s = t('t_disabled');
    else if (!onx) s = t('t_idle');
    else if (cur && goal) s = t('t_active') + ' · ' + cur + ' → ' + goal;
    else s = t('t_applying');
    setText('brightDesc', s);
    setVal('brightGoal', d.bright_goal_set || '');
    var info = 'max ' + (mx || '--');
    if (goal) info += ' · goal ' + goal;
    setText('brightInfo', info);
  }

  function renderBattery(d) {
    setText('sysBattery', (d.battery || '--') + t('pct'));
    setText('sysTemp', (d.temp_deg || '--') + t('deg'));
    var p = d.power;
    setText('sysPower', (p && p !== '0.0' ? p : '--') + ' ' + t('watt'));
  }

  function init() {
    bindSwitch('fanOn', 'fan_on');
    bindSwitch('fanKeep', 'fan_keep');
    bindRange('fanLevel', 'fanLevelVal', 'fan_level', ' / 5');
    bindSeg('fanTempSeg', 'fan_temp', { thr: 'fanTempThrWrap' });
    bindRange('fanTempThr', 'fanTempThrVal', 'fan_temp_thr', ' ' + t('deg'));

    bindSwitch('pumpOn', 'pump_on');
    bindSwitch('pumpKeep', 'pump_keep');
    bindRange('pumpLevel', 'pumpLevelVal', 'pump_level', ' / 4');
    bindSeg('pumpTempSeg', 'pump_temp', { thr: 'pumpTempThrWrap' });
    bindRange('pumpTempThr', 'pumpTempThrVal', 'pump_temp_thr', ' ' + t('deg'));

    bindSwitch('chargeOn', 'charge_on');
    bindRange('chargeThr', 'chargeThrVal', 'charge_thr', ' ' + t('pct'));
    bindSwitch('boostOn', 'boost_on');
    bindRange('boostThr', 'boostThrVal', 'boost_thr', ' ' + t('deg'));
    bindSwitch('boostHeat', 'boost_heat');

    bindSwitch('thermalOn', 'thermal_on');

    bindSwitch('rateOn', 'rate_on');
    bindNum('rateMax', 'rateApply', 'rate_max', 60, 2400, null, '');

    bindSwitch('brightOn', 'bright_on');
    bindNum('brightGoal', 'brightApply', 'bright_goal', 1, 20000, null, '');
  }

  g.CARDS = {
    init: init,
    render: function (d) {
      if (!d) return;
      renderFan(d); renderPump(d); renderCharge(d);
      renderThermal(d); renderRate(d); renderBright(d); renderBattery(d);
    },
    bindSwitch: bindSwitch, bindRange: bindRange, bindSeg: bindSeg, bindNum: bindNum,
    toast: toast, toastErr: toastErr, busy: busy, cmd: cmd,
    $: $, setText: setText, setVal: setVal, show: show, dot: dot, num: num, on: on,
    paintSeg: paintSeg
  };
})(window);
