(() => {
    'use strict';

    if (typeof DiscordNative === 'undefined' || typeof webpackChunkdiscord_app === 'undefined') {
        console.error('[Python3.16] Discord desktop only');
        return;
    }

    // ==================== HARD CLEANUP ====================
    try {
        if (window.__python316?.destroy) window.__python316.destroy();
    } catch {}
    ['__rpcSpoofer','rpcSpoofer','__gameTimeForge','__gameTimeForgeActive','__stopGameTimeForge',
     '__streamForge','__streamForgeActive','__stopStreamForge','__dtb','__nexus','__python316'].forEach(k => {
        try { delete window[k]; } catch {}
    });
    try { document.getElementById('py316-host')?.remove(); } catch {}

    // ==================== CONFIG ====================
    const __version = '4.3.0';
    const CFG = {
        brand: { name: 'Python3.16 Client', author: 'Python 3.16', version: __version },
        rpc:   { maxApps: 160, intervalMin: 48, intervalMax: 72 },
        game:  { titles: 340, batchSize: 14, delay: 880, wobble: true },
        stream:{ sessions: 48, batchSize: 9, delay: 780, wobble: true }
    };

    // ==================== UTILS ====================
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const uuid  = () => crypto.randomUUID();
    const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
    const now   = () => Date.now();

    let uiLog = () => {};
    let uiToast = () => {};
    let _lastToast = 0;
    const log = (msg, kind = 'info') => {
        const line = `[${new Date().toLocaleTimeString()}] ${msg}`;
        try { console.log(`[Python3.16] ${msg}`); } catch {}
        try { uiLog(line, kind); } catch {}
        if (kind === 'success' || kind === 'error') {
            const t = now();
            if (t - _lastToast > 700) { _lastToast = t; try { uiToast(msg, kind); } catch {} }
        }
    };

    // ==================== WEBPACK LAYER ====================
    const getWebpack = () => {
        const req = webpackChunkdiscord_app.push([[Symbol()], {}, r => r]);
        webpackChunkdiscord_app.pop();
        return req;
    };

    const findModule = (pred) => {
        const wp = getWebpack();
        return Object.values(wp.c).find(pred)?.exports || null;
    };

    const getRest = () => {
        const wp = getWebpack();
        try {
            for (const [id, fn] of Object.entries(wp.m || {})) {
                if (typeof fn === 'function' && fn.toString().includes('HTTPUtils')) {
                    const exp = wp(id);
                    const c = Object.values(exp).find(e => e && typeof e.get === 'function' && typeof e.post === 'function');
                    if (c) return c;
                }
            }
        } catch {}
        for (const mod of Object.values(wp.c)) {
            if (!mod?.exports) continue;
            for (const t of [mod.exports, mod.exports.default, ...Object.values(mod.exports || {})]) {
                if (t && typeof t.get === 'function' && typeof t.post === 'function') return t;
            }
        }
        return null;
    };

    const getGateway = () => {
        const wp = getWebpack();
        for (const mod of Object.values(wp.c)) {
            if (!mod?.exports) continue;
            const m = mod.exports.default || mod.exports;
            if (m && typeof m.send === 'function' && typeof m.isConnected === 'function') return m;
        }
        return null;
    };

    const getAuthToken = () => {
        try {
            const wp = getWebpack();
            for (const mod of Object.values(wp.c)) {
                if (!mod?.exports) continue;
                const m = mod.exports.default || mod.exports;
                if (typeof m?.getToken === 'function') {
                    const t = m.getToken();
                    if (t && typeof t === 'string') return t;
                }
            }
        } catch {}
        try {
            const raw = localStorage.getItem('token');
            if (raw) return raw.replace(/^"|"$/g, '');
        } catch {}
        return null;
    };

    // ==================== FINGERPRINT ====================
    const generateFingerprint = async (uid) => {
        const enc = new TextEncoder();
        const sha = async d => new Uint8Array(await crypto.subtle.digest('SHA-256', d));
        const seed = `${uid || 'anon'}_python316_v4`;
        const seedBuf = await sha(enc.encode(seed));
        const guidHex = Array.from(seedBuf.slice(0, 16)).map(b => b.toString(16).padStart(2, '0')).join('');
        const [h1, h2, h3, h4] = await Promise.all([
            sha(enc.encode(guidHex + uid)),
            sha(enc.encode('pe_header_' + uid)),
            sha(enc.encode('pe_section_' + uid)),
            sha(enc.encode('pe_cert_' + uid))
        ]);
        const buf = new Uint8Array(146);
        const view = new DataView(buf.buffer);
        buf[0] = 1; buf[1] = 1;
        view.setBigUint64(2, 65432100n, true);
        view.setUint32(10, Math.floor(now() / 1000) - 86400 * 16, true);
        view.setUint32(14, 0x02500000, true);
        buf.set(h2, 18); buf.set(h1, 50); buf.set(h3, 82); buf.set(h4, 114);
        const key = await sha(enc.encode(uid + 'https://discord.com/careers'));
        for (let i = 1; i < buf.length; i++) buf[i] ^= key[(i - 1) & 31];
        let bin = '';
        for (let i = 0; i < buf.length; i++) bin += String.fromCharCode(buf[i]);
        return btoa(bin);
    };

    // ==================== CONTEXT ====================
    let ctx = null;
    const ensureContext = async (force = false) => {
        if (ctx && !force) return ctx;
        const rest = getRest();
        if (!rest) throw new Error('REST module missing');
        const me = await rest.get({ url: '/users/@me', query: { with_analytics_token: true } });
        const body = me?.body || me;
        if (!body?.analytics_token) throw new Error('analytics_token missing');
        const fingerprint = await generateFingerprint(body.id);
        ctx = {
            rest,
            token: body.analytics_token,
            userId: body.id,
            username: body.username || 'unknown',
            globalName: body.global_name || body.username,
            fingerprint
        };
        return ctx;
    };

    // ==================== RPC ====================
    let rpcInterval = null;
    let currentActivity = null;

    const stopRpc = () => {
        if (rpcInterval) {
            clearTimeout(rpcInterval);
            clearInterval(rpcInterval);
            rpcInterval = null;
        }
        currentActivity = null;
        const gw = getGateway();
        if (gw?.isConnected()) {
            gw.send(3, { activities: [], status: 'online', afk: false, since: 0 });
        }
        log('RPC stopped', 'warn');
    };

    const applyRpc = (name, applicationId = null) => {
        const gw = getGateway();
        if (!gw?.isConnected()) {
            log('Gateway offline', 'error');
            return false;
        }
        const payload = {
            activities: [{
                name: String(name).slice(0, 128),
                type: 0,
                application_id: applicationId ? String(applicationId) : undefined,
                details: 'Python3.16 Client',
                state: 'Active',
                timestamps: { start: now() }
            }],
            status: 'online',
            afk: false,
            since: 0
        };
        gw.send(3, payload);
        currentActivity = name;
        return true;
    };

    const startRotation = async () => {
        if (rpcInterval) throw new Error('Rotation already active');
        const c = await ensureContext();
        let apps = [];
        try {
            const res = await c.rest.get({ url: '/applications/detectable' });
            apps = res?.body || res || [];
            if (!Array.isArray(apps)) apps = Object.values(apps);
        } catch {
            try {
                apps = await (await fetch('https://cdn.discordapp.com/detectables/games.json')).json();
            } catch {
                throw new Error('Catalog unreachable');
            }
        }
        const catalog = apps.filter(a => a?.id).sort(() => Math.random() - 0.5).slice(0, CFG.rpc.maxApps);
        if (!catalog.length) throw new Error('Empty catalog');

        let i = 0;
        const nextDelay = () => (CFG.rpc.intervalMin + Math.random() * (CFG.rpc.intervalMax - CFG.rpc.intervalMin)) * 1000;
        const step = () => {
            if (!rpcInterval) return;
            if (i >= catalog.length) {
                stopRpc();
                try { ui.onRpcEnded?.(); } catch {}
                return;
            }
            const app = catalog[i++];
            applyRpc(app.name || 'Unknown', app.id);
            log(`RPC → ${app.name}`, 'info');
            rpcInterval = setTimeout(step, nextDelay());
        };
        rpcInterval = setTimeout(step, 0);
    };

    // ==================== PROFILE ACTIONS ====================
    const patchMe = async (body) => {
        const c = await ensureContext();
        const res = await c.rest.patch({ url: '/users/@me', body });
        if (!(res?.status === 200 || res?.status === 204 || res?.ok || res?.body)) {
            throw new Error(`HTTP ${res?.status || '?'}`);
        }
        return res;
    };

    const changeBio = (bio) => patchMe({ bio: String(bio || '').slice(0, 190) });
    const changeDisplayName = (name) => patchMe({ global_name: String(name || '').slice(0, 32) });
    const changePronouns = (pronouns) => patchMe({ pronouns: String(pronouns || '').slice(0, 40) });
    const changeAccentColor = (hex) => {
        let color = null;
        if (hex && /^#?[0-9a-fA-F]{6}$/.test(hex)) color = parseInt(hex.replace('#', ''), 16);
        return patchMe({ accent_color: color });
    };

    const changeCustomStatus = async (text, emojiName = null) => {
        const c = await ensureContext();
        const res = await c.rest.patch({
            url: '/users/@me/settings',
            body: {
                custom_status: {
                    text: String(text || '').slice(0, 128),
                    emoji_name: emojiName || null,
                    emoji_id: null
                }
            }
        });
        if (!(res?.status === 200 || res?.status === 204 || res?.ok)) throw new Error(`HTTP ${res?.status || '?'}`);
    };

    const setHypeSquad = async (houseId) => {
        const c = await ensureContext();
        if (houseId === null || houseId === 0) {
            await c.rest.delete({ url: '/hypesquad/online' });
            return;
        }
        const res = await c.rest.post({ url: '/hypesquad/online', body: { house_id: houseId } });
        if (!(res?.status === 200 || res?.status === 204 || res?.ok)) throw new Error(`HTTP ${res?.status || '?'}`);
    };

    const setStatus = (status) => {
        const gw = getGateway();
        if (!gw?.isConnected()) return false;
        gw.send(3, { activities: currentActivity ? [{ name: currentActivity, type: 0 }] : [], status, afk: false, since: 0 });
        return true;
    };

    const setGhostMode = (on) => setStatus(on ? 'invisible' : 'online');

    // ==================== MARK ALL READ ====================
    const markAllRead = () => {
        try {
            const wp = getWebpack();
            const channelStore = Object.values(wp.c).find(m => m?.exports?.getChannels)?.exports;
            if (!channelStore) return false;
            const channels = channelStore.getChannels();
            const dispatcher = Object.values(wp.c).find(m => m?.exports?.dispatch || m?.exports?.default?.dispatch);
            const dispatch = dispatcher?.exports?.dispatch || dispatcher?.exports?.default?.dispatch;
            if (!dispatch) return false;
            dispatch({ type: 'BULK_ACK_CHANNELS', channels: Object.keys(channels) });
            log('All channels marked read', 'success');
            return true;
        } catch {
            return false;
        }
    };

    // ==================== GAME FORGE ====================
    let gameState = { active: false, stop: null, progress: 0 };

    const startGameForge = async (totalHours) => {
        if (gameState.active) throw new Error('Game forge already running');
        const c = await ensureContext();
        let raw = [];
        try {
            const res = await c.rest.get({ url: '/applications/detectable' });
            raw = res?.body || res || [];
        } catch {
            try { raw = await (await fetch('https://cdn.discordapp.com/detectables/games.json')).json(); }
            catch { throw new Error('Catalog fail'); }
        }
        if (!Array.isArray(raw)) raw = Object.values(raw);

        const catalog = [];
        const seen = new Set();
        for (const item of raw) {
            if (!item?.id || seen.has(item.id)) continue;
            const win = item.executables?.find(e => e?.os === 'win32')?.name;
            if (!win && item.executables?.length) continue;
            const exe = (win || (item.name || 'game').replace(/[^a-zA-Z0-9]/g, '').toLowerCase() + '.exe')
                .replace(/[<>:"/\\|?*]/g, '');
            seen.add(item.id);
            catalog.push({ id: String(item.id), name: item.name || 'Unknown', exe });
        }
        if (!catalog.length) throw new Error('Empty catalog');

        const selected = catalog.sort(() => Math.random() - 0.5).slice(0, Math.min(CFG.game.titles, catalog.length));
        const hoursPer = totalHours / selected.length;
        log(`Game forge → ${selected.length} titles · ~${hoursPer.toFixed(1)}h each`, 'info');

        const session = { heartbeatId: uuid(), signature: uuid(), seq: 0 };

        const buildLaunch = (game, ts) => ({
            type: 'launch_game',
            properties: {
                client_track_timestamp: ts,
                client_heartbeat_session_id: session.heartbeatId,
                event_sequence_number: ++session.seq,
                game: game.name,
                game_id: game.id,
                verified: true,
                elevated: false,
                is_launcher: false,
                game_platform: 'desktop',
                detection_method: 'verified_game',
                is_overlay_enabled: false,
                is_overlay_game_enabled: true,
                is_overlay_game_source: 'OOP_DEFAULT_DATABASE',
                fullscreen_type: 'UNKNOWN',
                hardware_display_count: 1,
                overlay_method: 'Disabled',
                activity_status_enabled: true,
                activity_status_shared_guilds: [],
                current_user_status: 'online',
                game_detection_enabled: true,
                executable_path: game.exe,
                voice_channel_id: null,
                voice_channel_type: null,
                voice_channel_bitrate: null,
                voice_channel_guild_id: null,
                hidden_by_distributor: false,
                game_metadata: null,
                executable_fingerprint: c.fingerprint,
                client_performance_cpu: null,
                client_performance_memory: null,
                cpu_core_count: null,
                accessibility_features: 0,
                rendered_locale: 'en-US',
                launch_signature: session.signature,
                client_rtc_state: null,
                client_app_state: 'focused',
                client_send_timestamp: ts
            }
        });

        const buildHB = (game, dur, sid, initial, final, ts) => ({
            type: 'running_game_heartbeat',
            properties: {
                client_track_timestamp: ts,
                client_heartbeat_session_id: session.heartbeatId,
                event_sequence_number: ++session.seq,
                game_id: game.id,
                game_name: game.name,
                game_metadata: null,
                game_executable: game.exe,
                game_detection_enabled: true,
                initial_heartbeat: initial,
                final_heartbeat: final,
                game_session_id: sid,
                duration_tracked_ms: dur,
                rtc_connection_id: null,
                media_session_id: null,
                launch_signature: session.signature,
                client_app_state: 'focused',
                client_send_timestamp: ts
            }
        });

        const triplet = (game, base) => {
            const drift = CFG.game.wobble ? 1 + (Math.random() * 0.07 - 0.035) : 1;
            const hours = Math.max(0.3, base * drift);
            const dur = Math.floor(hours * 3600 * 1000);
            const start = now() - dur - Math.floor(Math.random() * 6 * 86400000);
            const sid = uuid();
            return {
                hours,
                events: [
                    buildHB(game, 0, sid, true, false, start),
                    buildLaunch(game, start + 3200),
                    buildHB(game, dur, sid, false, true, start + dur)
                ]
            };
        };

        gameState.active = true;
        gameState.progress = 0;
        gameState.stop = () => { gameState.active = false; };

        let logged = 0, forged = 0;
        const batches = Math.ceil(selected.length / CFG.game.batchSize);

        try {
            for (let i = 0; i < batches; i++) {
                if (!gameState.active) break;
                const chunk = selected.slice(i * CFG.game.batchSize, (i + 1) * CFG.game.batchSize);
                const events = [];
                let ch = 0;
                for (const g of chunk) {
                    const t = triplet(g, hoursPer);
                    events.push(...t.events);
                    ch += t.hours;
                }
                try {
                    const res = await c.rest.post({ url: '/science', body: { token: c.token, events } });
                    const ok = res?.status === 204 || res?.status === 200 || res?.ok || res?.body == null;
                    if (ok) {
                        forged += chunk.length;
                        logged += ch;
                        gameState.progress = Math.round((forged / selected.length) * 100);
                        log(`Game ${i + 1}/${batches} · +${ch.toFixed(1)}h · total ${logged.toFixed(1)}h`, 'success');
                    } else {
                        log(`Game batch ${i + 1} → ${res?.status}`, 'warn');
                    }
                } catch (e) {
                    log(`Game batch ${i + 1}: ${e?.message || e}`, 'error');
                    if (String(e).includes('429')) {
                        await sleep(10500);
                        i--;
                        continue;
                    }
                }
                await sleep(CFG.game.delay + Math.floor(Math.random() * 320));
            }
            if (gameState.active) log(`Game forge complete → ${forged}/${selected.length} · ${logged.toFixed(1)}h`, 'success');
        } finally {
            gameState.active = false;
            gameState.stop = null;
            gameState.progress = 0;
        }
    };

    // ==================== STREAM FORGE ====================
    let streamState = { active: false, stop: null, progress: 0 };

    const startStreamForge = async (totalHours) => {
        if (streamState.active) throw new Error('Stream forge already running');
        const c = await ensureContext();
        const sessionCount = Math.min(CFG.stream.sessions, Math.max(14, Math.floor(totalHours / 8.5)));
        const hoursPer = totalHours / sessionCount;
        log(`Stream forge → ${sessionCount} sessions · ~${hoursPer.toFixed(1)}h`, 'info');

        const session = { heartbeatId: uuid(), signature: uuid(), seq: 0 };

        const build = (hours) => {
            const dur = Math.floor(hours * 3600 * 1000);
            const start = now() - dur - Math.floor(Math.random() * 4.5 * 86400000);
            const streamId = uuid();
            return {
                hours,
                events: [
                    {
                        type: 'stream_start',
                        properties: {
                            client_track_timestamp: start,
                            client_heartbeat_session_id: session.heartbeatId,
                            event_sequence_number: ++session.seq,
                            stream_id: streamId,
                            stream_key: `call:${uuid()}:1`,
                            application_id: null,
                            executable_fingerprint: c.fingerprint,
                            client_app_state: 'focused',
                            client_send_timestamp: start,
                            launch_signature: session.signature
                        }
                    },
                    {
                        type: 'stream_heartbeat',
                        properties: {
                            client_track_timestamp: start + 700,
                            client_heartbeat_session_id: session.heartbeatId,
                            event_sequence_number: ++session.seq,
                            stream_id: streamId,
                            duration_tracked_ms: 0,
                            initial_heartbeat: true,
                            final_heartbeat: false,
                            executable_fingerprint: c.fingerprint,
                            client_app_state: 'focused',
                            client_send_timestamp: start + 700,
                            launch_signature: session.signature
                        }
                    },
                    {
                        type: 'stream_heartbeat',
                        properties: {
                            client_track_timestamp: start + dur,
                            client_heartbeat_session_id: session.heartbeatId,
                            event_sequence_number: ++session.seq,
                            stream_id: streamId,
                            duration_tracked_ms: dur,
                            initial_heartbeat: false,
                            final_heartbeat: true,
                            executable_fingerprint: c.fingerprint,
                            client_app_state: 'focused',
                            client_send_timestamp: start + dur,
                            launch_signature: session.signature
                        }
                    },
                    {
                        type: 'stream_end',
                        properties: {
                            client_track_timestamp: start + dur + 350,
                            client_heartbeat_session_id: session.heartbeatId,
                            event_sequence_number: ++session.seq,
                            stream_id: streamId,
                            duration_tracked_ms: dur,
                            executable_fingerprint: c.fingerprint,
                            client_app_state: 'focused',
                            client_send_timestamp: start + dur + 350,
                            launch_signature: session.signature
                        }
                    }
                ]
            };
        };

        streamState.active = true;
        streamState.progress = 0;
        streamState.stop = () => { streamState.active = false; };

        let logged = 0, forged = 0;
        const batches = Math.ceil(sessionCount / CFG.stream.batchSize);

        try {
            for (let i = 0; i < batches; i++) {
                if (!streamState.active) break;
                const size = Math.min(CFG.stream.batchSize, sessionCount - i * CFG.stream.batchSize);
                const events = [];
                let ch = 0;
                for (let j = 0; j < size; j++) {
                    const drift = CFG.stream.wobble ? 1 + (Math.random() * 0.07 - 0.035) : 1;
                    const t = build(Math.max(0.4, hoursPer * drift));
                    events.push(...t.events);
                    ch += t.hours;
                }
                try {
                    const res = await c.rest.post({ url: '/science', body: { token: c.token, events } });
                    const ok = res?.status === 204 || res?.status === 200 || res?.ok || res?.body == null;
                    if (ok) {
                        forged += size;
                        logged += ch;
                        streamState.progress = Math.round((forged / sessionCount) * 100);
                        log(`Stream ${i + 1}/${batches} · +${ch.toFixed(1)}h · total ${logged.toFixed(1)}h`, 'success');
                    } else {
                        log(`Stream batch ${i + 1} → ${res?.status}`, 'warn');
                    }
                } catch (e) {
                    log(`Stream batch ${i + 1}: ${e?.message || e}`, 'error');
                    if (String(e).includes('429')) {
                        await sleep(9200);
                        i--;
                        continue;
                    }
                }
                await sleep(CFG.stream.delay + Math.floor(Math.random() * 260));
            }
            if (streamState.active) log(`Stream forge complete → ${forged} sessions · ${logged.toFixed(1)}h`, 'success');
        } finally {
            streamState.active = false;
            streamState.stop = null;
            streamState.progress = 0;
        }
    };

    // ==================== UI ====================
    const ui = {};

    const setupUI = () => {
        const host = document.createElement('div');
        host.id = 'py316-host';
        (document.body || document.documentElement).appendChild(host);
        const root = host.attachShadow({ mode: 'open' });

        const style = document.createElement('style');
        style.textContent = `
            :host { all: initial; }
            * { box-sizing: border-box; font-family: 'Segoe UI', system-ui, -apple-system, sans-serif; }

            .py-load {
                position: fixed; inset: 0; background: #09090b;
                display: flex; flex-direction: column; align-items: center; justify-content: center;
                z-index: 2147483647; transition: opacity .65s ease;
            }
            .py-load.done { opacity: 0; pointer-events: none; }
            .py-load-inner { text-align: center; animation: pyIn .8s cubic-bezier(.16,1,.3,1); }
            @keyframes pyIn { from { opacity:0; transform:scale(.94) translateY(12px); } to { opacity:1; transform:none; } }
            .py-logo { width: 110px; height: 110px; filter: drop-shadow(0 0 24px rgba(88,101,242,.5)); margin-bottom: 16px; }
            .py-title {
                font-size: 28px; font-weight: 800; letter-spacing: 5px; margin: 0 0 14px;
                background: linear-gradient(90deg,#5865f2,#a259ff,#00d4ff,#5865f2);
                background-size: 280% 100%; -webkit-background-clip: text; background-clip: text;
                -webkit-text-fill-color: transparent; animation: pyGrad 4.5s linear infinite;
            }
            @keyframes pyGrad { to { background-position: 280% 50%; } }
            .py-bar { width: 260px; height: 3px; background: rgba(255,255,255,.06); border-radius: 4px; overflow: hidden; margin: 0 auto 10px; }
            .py-bar > div { height: 100%; width: 0; background: linear-gradient(90deg,#5865f2,#00d4ff); transition: width .2s; }
            .py-status { color: #8b8f9a; font-size: 11px; letter-spacing: 1.2px; font-family: ui-monospace, monospace; }

            .py-panel {
                position: fixed; width: 400px;
                background: rgba(18,19,23,.94); backdrop-filter: blur(20px);
                border: 1px solid rgba(255,255,255,.07); border-radius: 14px;
                box-shadow: 0 22px 60px rgba(0,0,0,.7);
                color: #dbdee1; font-size: 13px; z-index: 2147483646; overflow: hidden;
                opacity: 0; transform: scale(.97) translateY(6px);
                transition: opacity .25s, transform .25s cubic-bezier(.16,1,.3,1);
            }
            .py-panel.visible { opacity: 1; transform: none; }
            .py-panel.hidden { opacity: 0; pointer-events: none; }

            .py-head {
                display: flex; align-items: center; justify-content: space-between;
                padding: 11px 13px;
                background: linear-gradient(135deg, rgba(88,101,242,.95), rgba(0,180,220,.85));
                cursor: move; user-select: none;
            }
            .py-brand { display: flex; align-items: center; gap: 8px; font-weight: 800; font-size: 13.5px; color: #fff; letter-spacing: .8px; }
            .py-brand svg { width: 20px; height: 20px; }
            .py-icon {
                width: 24px; height: 24px; border: none; background: rgba(255,255,255,.15);
                color: #fff; border-radius: 6px; cursor: pointer; font-size: 15px;
                display: flex; align-items: center; justify-content: center;
            }
            .py-icon:hover { background: rgba(255,255,255,.28); }

            .py-tabs { display: flex; gap: 2px; padding: 7px 7px 0; background: rgba(14,15,18,.8); border-bottom: 1px solid rgba(255,255,255,.05); overflow-x: auto; }
            .py-tabs::-webkit-scrollbar { display: none; }
            .py-tab {
                padding: 6px 10px; border: none; background: transparent; color: #949ba4;
                font-size: 11px; font-weight: 600; cursor: pointer; border-radius: 6px 6px 0 0; white-space: nowrap;
            }
            .py-tab:hover { color: #fff; background: rgba(255,255,255,.05); }
            .py-tab.active { color: #fff; background: rgba(255,255,255,.08); position: relative; }
            .py-tab.active::after {
                content: ''; position: absolute; bottom: -1px; left: 6px; right: 6px; height: 2px;
                background: linear-gradient(90deg,#5865f2,#00d4ff); border-radius: 2px;
            }

            .py-body { padding: 12px; display: flex; flex-direction: column; gap: 10px; max-height: 56vh; overflow-y: auto; }
            .py-body::-webkit-scrollbar { width: 4px; }
            .py-body::-webkit-scrollbar-thumb { background: #35373d; border-radius: 2px; }

            .py-content { display: none; flex-direction: column; gap: 10px; }
            .py-content.active { display: flex; animation: pyFade .2s ease; }
            @keyframes pyFade { from { opacity:0; transform:translateY(3px); } to { opacity:1; transform:none; } }

            .py-sec {
                background: rgba(0,0,0,.22); border: 1px solid rgba(255,255,255,.05);
                border-radius: 9px; padding: 11px;
            }
            .py-sec-h { display: flex; align-items: center; justify-content: space-between; font-weight: 600; color: #f0f1f3; font-size: 12px; margin-bottom: 5px; }
            .py-sec-d { font-size: 10.5px; color: #949ba4; line-height: 1.4; margin-bottom: 8px; }

            input[type=text], input[type=number], input[type=color], textarea {
                width: 100%; padding: 7px 10px; background: rgba(0,0,0,.32);
                border: 1px solid rgba(255,255,255,.08); border-radius: 6px; color: #f2f3f5;
                font-size: 12px; outline: none; font-family: inherit;
            }
            input:focus, textarea:focus { border-color: #5865f2; box-shadow: 0 0 0 2px rgba(88,101,242,.15); }
            textarea { min-height: 58px; resize: vertical; }

            .py-btn {
                width: 100%; padding: 8px 11px; border: none; border-radius: 6px;
                font-size: 12px; font-weight: 600; cursor: pointer;
                display: flex; align-items: center; justify-content: center; gap: 5px;
            }
            .py-btn:active { transform: scale(.98); }
            .py-btn-p { background: linear-gradient(135deg,#5865f2,#4752c4); color: #fff; }
            .py-btn-p:hover { filter: brightness(1.07); }
            .py-btn-p:disabled { background: #35373d; color: #6b6f78; cursor: not-allowed; }
            .py-btn-d { background: linear-gradient(135deg,#ed4245,#c93a3d); color: #fff; }
            .py-btn-g { background: transparent; color: #b5bac1; border: 1px solid rgba(255,255,255,.12); }
            .py-btn-g:hover { background: rgba(255,255,255,.05); color: #f2f3f5; }
            .py-btn-row { display: flex; gap: 6px; }
            .py-btn-mini { border: none; background: rgba(255,255,255,.06); color: #b5bac1; font-size: 10px; padding: 3px 8px; border-radius: 5px; cursor: pointer; font-weight: 600; }
            .py-btn-mini:hover { background: rgba(255,255,255,.12); color: #fff; }

            .py-toggle { position: relative; width: 36px; height: 19px; flex-shrink: 0; }
            .py-toggle input { opacity: 0; width: 0; height: 0; }
            .py-slider {
                position: absolute; inset: 0; background: #35373d; border-radius: 19px; cursor: pointer; transition: .22s;
            }
            .py-slider::before {
                content: ''; position: absolute; width: 13px; height: 13px; left: 3px; top: 3px;
                background: #fff; border-radius: 50%; transition: transform .22s cubic-bezier(.16,1,.3,1);
            }
            .py-toggle input:checked + .py-slider { background: linear-gradient(135deg,#5865f2,#00d4ff); }
            .py-toggle input:checked + .py-slider::before { transform: translateX(16px); }

            .py-log {
                height: 120px; overflow-y: auto; font-family: ui-monospace, Menlo, monospace;
                font-size: 10px; line-height: 1.5; color: #949ba4; padding: 5px;
                background: rgba(0,0,0,.28); border-radius: 5px; user-select: text;
            }
            .py-log::-webkit-scrollbar { width: 4px; }
            .py-log::-webkit-scrollbar-thumb { background: #35373d; border-radius: 2px; }
            .py-log-line { white-space: pre-wrap; word-break: break-word; }
            .py-log-success { color: #3ba55d; }
            .py-log-warn { color: #faa81a; }
            .py-log-error { color: #ed4245; }

            .py-foot { padding: 9px 12px 11px; border-top: 1px solid rgba(255,255,255,.05); background: rgba(0,0,0,.18); }
            .py-author { font-size: 9.5px; color: #5c5f68; text-align: center; margin-top: 5px; }

            .py-toasts { position: fixed; right: 16px; bottom: 16px; display: flex; flex-direction: column; gap: 8px; z-index: 2147483644; pointer-events: none; }
            .py-toast {
                min-width: 180px; max-width: 300px; padding: 9px 12px; border-radius: 8px;
                font-size: 12px; color: #fff; background: rgba(30,31,34,.96);
                border-left: 3px solid #5865f2; box-shadow: 0 8px 24px rgba(0,0,0,.5);
                animation: pyToastIn .22s cubic-bezier(.16,1,.3,1);
            }
            .py-toast.error { border-left-color: #ed4245; }
            .py-toast.success { border-left-color: #3ba55d; }
            @keyframes pyToastIn { from { opacity:0; transform: translateY(8px); } to { opacity:1; transform:none; } }

            .py-orb {
                position: fixed; width: 48px; height: 48px; border-radius: 50%;
                background: linear-gradient(135deg,#5865f2,#00d4ff);
                display: none; align-items: center; justify-content: center; cursor: pointer;
                box-shadow: 0 6px 22px rgba(88,101,242,.5); z-index: 2147483645;
                border: 2px solid rgba(255,255,255,.16); transition: transform .18s;
            }
            .py-orb:hover { transform: scale(1.07); }
            .py-orb.visible { display: flex; }
            .py-orb svg { width: 24px; height: 24px; }
            .py-orb.active::after {
                content: ''; position: absolute; top: -2px; right: -2px; width: 10px; height: 10px;
                background: #3ba55d; border: 2px solid #121317; border-radius: 50%;
                animation: pyBeat 1.25s infinite;
            }
            @keyframes pyBeat { 0%,100%{opacity:1;transform:scale(1)} 50%{opacity:.4;transform:scale(.8)} }

            .py-warn {
                font-size: 10px; color: #faa81a; background: rgba(250,168,26,.08);
                border: 1px solid rgba(250,168,26,.16); border-radius: 6px; padding: 7px; line-height: 1.4; margin-bottom: 6px;
            }
            .py-token {
                font-family: ui-monospace, monospace; font-size: 10px; background: rgba(0,0,0,.4);
                border: 1px solid rgba(255,255,255,.08); border-radius: 6px; padding: 8px;
                color: #f2f3f5; word-break: break-all; max-height: 80px; overflow-y: auto; user-select: all;
            }
            .py-row { display: flex; align-items: center; gap: 8px; margin: 6px 0; }
            .py-row label { font-size: 11.5px; color: #b5bac1; min-width: 52px; }
        `;
        root.appendChild(style);

        const logo = `<svg viewBox="0 0 100 100" fill="none"><defs><linearGradient id="g" x1="0%" y1="0%" x2="100%" y2="100%"><stop offset="0%" stop-color="#5865f2"/><stop offset="50%" stop-color="#a259ff"/><stop offset="100%" stop-color="#00d4ff"/></linearGradient></defs><path d="M50 7 L85 27 L85 73 L50 93 L15 73 L15 27 Z" stroke="url(#g)" stroke-width="2.2" fill="rgba(88,101,242,.07)"/><text x="50" y="61" text-anchor="middle" fill="url(#g)" font-size="26" font-weight="800" font-family="Segoe UI">3.16</text></svg>`;

        // Loading
        const load = document.createElement('div');
        load.className = 'py-load';
        load.innerHTML = `
            <div class="py-load-inner">
                <div class="py-logo">${logo.replace(/id="g"/g,'id="g0"').replace(/url\(#g\)/g,'url(#g0)')}</div>
                <h1 class="py-title">PYTHON3.16</h1>
                <div class="py-bar"><div></div></div>
                <div class="py-status">Booting<span>...</span></div>
            </div>`;
        root.appendChild(load);
        const bar = load.querySelector('.py-bar > div');
        const st = load.querySelector('.py-status');
        const phases = [[0,15,'Modules'],[15,35,'Hooks'],[35,55,'Auth'],[55,75,'Fingerprint'],[75,90,'Gateway'],[90,100,'Ready']];
        const t0 = now();
        const tick = () => {
            const p = Math.min(100, (now() - t0) / 3800 * 100);
            bar.style.width = p + '%';
            for (const [a,b,txt] of phases) if (p >= a && p < b) { st.innerHTML = txt + '<span>...</span>'; break; }
            if (p < 100) requestAnimationFrame(tick);
        };
        tick();

        // Panel
        const panel = document.createElement('div');
        panel.className = 'py-panel';
        panel.innerHTML = `
            <div class="py-head">
                <div class="py-brand">${logo.replace(/id="g"/g,'id="g1"').replace(/url\(#g\)/g,'url(#g1)')}<span>PYTHON3.16</span></div>
                <button class="py-icon py-min">−</button>
            </div>
            <div class="py-tabs">
                <button class="py-tab active" data-t="rpc">RPC</button>
                <button class="py-tab" data-t="profile">Profile</button>
                <button class="py-tab" data-t="tools">Tools</button>
                <button class="py-tab" data-t="forge">Forge</button>
                <button class="py-tab" data-t="log">Log</button>
            </div>
            <div class="py-body">
                <div class="py-content active" data-c="rpc">
                    <div class="py-sec">
                        <div class="py-sec-h">Playing Status</div>
                        <div class="py-sec-d">Force a custom Playing activity via Gateway.</div>
                        <input type="text" id="py-name" placeholder="Game name…">
                        <div class="py-btn-row" style="margin-top:8px">
                            <button class="py-btn py-btn-p" id="py-apply">Apply</button>
                            <button class="py-btn py-btn-g" id="py-stop">Stop</button>
                        </div>
                    </div>
                    <div class="py-sec">
                        <div class="py-sec-h">
                            <span>Catalog Rotation</span>
                            <label class="py-toggle"><input type="checkbox" id="py-rot"><span class="py-slider"></span></label>
                        </div>
                        <div class="py-sec-d">Auto-cycle detectable games.</div>
                    </div>
                </div>

                <div class="py-content" data-c="profile">
                    <div class="py-sec">
                        <div class="py-sec-h">Display Name</div>
                        <input type="text" id="py-dname" maxlength="32" placeholder="Display name…">
                        <button class="py-btn py-btn-p" id="py-dname-btn" style="margin-top:7px">Update</button>
                    </div>
                    <div class="py-sec">
                        <div class="py-sec-h">Bio</div>
                        <textarea id="py-bio" maxlength="190" placeholder="Bio…"></textarea>
                        <div class="py-btn-row" style="margin-top:7px">
                            <button class="py-btn py-btn-p" id="py-bio-btn">Save</button>
                            <button class="py-btn py-btn-g" id="py-bio-clr">Clear</button>
                        </div>
                    </div>
                    <div class="py-sec">
                        <div class="py-sec-h">Pronouns</div>
                        <input type="text" id="py-pron" maxlength="40" placeholder="he/him, she/her…">
                        <button class="py-btn py-btn-p" id="py-pron-btn" style="margin-top:7px">Set</button>
                    </div>
                    <div class="py-sec">
                        <div class="py-sec-h">Custom Status</div>
                        <input type="text" id="py-cstat" placeholder="Status text…">
                        <button class="py-btn py-btn-p" id="py-cstat-btn" style="margin-top:7px">Apply</button>
                    </div>
                    <div class="py-sec">
                        <div class="py-sec-h">Accent Color</div>
                        <div class="py-row">
                            <input type="color" id="py-acc" value="#5865f2" style="width:42px;height:28px;padding:1px;cursor:pointer">
                            <button class="py-btn py-btn-p" id="py-acc-btn" style="flex:1">Set</button>
                        </div>
                    </div>
                    <div class="py-sec">
                        <div class="py-sec-h">HypeSquad</div>
                        <div class="py-btn-row">
                            <button class="py-btn py-btn-g" data-h="1">Bravery</button>
                            <button class="py-btn py-btn-g" data-h="2">Brilliance</button>
                            <button class="py-btn py-btn-g" data-h="3">Balance</button>
                        </div>
                        <button class="py-btn py-btn-g" id="py-hype-out" style="margin-top:6px">Leave</button>
                    </div>
                    <div class="py-sec">
                        <div class="py-sec-h"><span>Token</span><button class="py-btn-mini" id="py-tok-show">Show</button></div>
                        <div class="py-warn">Never share your token.</div>
                        <div id="py-tok-box"></div>
                    </div>
                </div>

                <div class="py-content" data-c="tools">
                    <div class="py-sec">
                        <div class="py-sec-h">
                            <span>Ghost Mode</span>
                            <label class="py-toggle"><input type="checkbox" id="py-ghost"><span class="py-slider"></span></label>
                        </div>
                        <div class="py-sec-d">Force invisible instantly.</div>
                    </div>
                    <div class="py-sec">
                        <div class="py-sec-h">Presence</div>
                        <div class="py-btn-row">
                            <button class="py-btn py-btn-g" data-s="online">Online</button>
                            <button class="py-btn py-btn-g" data-s="idle">Idle</button>
                            <button class="py-btn py-btn-g" data-s="dnd">DND</button>
                        </div>
                    </div>
                    <div class="py-sec">
                        <div class="py-sec-h">Cleanup</div>
                        <button class="py-btn py-btn-p" id="py-read">Mark All Read</button>
                    </div>
                    <div class="py-sec">
                        <div class="py-sec-h">Reset Token</div>
                        <div class="py-sec-d">Force logout + new token.</div>
                        <button class="py-btn py-btn-d" id="py-reset">Reset</button>
                    </div>
                </div>

                <div class="py-content" data-c="forge">
                    <div class="py-sec">
                        <div class="py-sec-h">Game Time Forge</div>
                        <div class="py-sec-d">Inject fake playtime.</div>
                        <div class="py-row">
                            <label>Hours</label>
                            <input type="number" id="py-gh" value="4000" min="1" max="120000">
                        </div>
                        <button class="py-btn py-btn-p" id="py-gstart" style="margin-top:7px">Start</button>
                    </div>
                    <div class="py-sec">
                        <div class="py-sec-h">Stream Time Forge</div>
                        <div class="py-sec-d">Inject fake stream hours.</div>
                        <div class="py-row">
                            <label>Hours</label>
                            <input type="number" id="py-sh" value="800" min="1" max="120000">
                        </div>
                        <button class="py-btn py-btn-p" id="py-sstart" style="margin-top:7px">Start</button>
                    </div>
                </div>

                <div class="py-content" data-c="log">
                    <div class="py-sec">
                        <div class="py-sec-h"><span>Log</span><button class="py-btn-mini" id="py-log-clr">Clear</button></div>
                        <div class="py-log" id="py-log"></div>
                    </div>
                </div>
            </div>
            <div class="py-foot">
                <button class="py-btn py-btn-d" id="py-kill">Stop Everything</button>
                <div class="py-author" id="py-status-line">Python3.16 · v${CFG.brand.version}</div>
            </div>`;
        root.appendChild(panel);

        const orb = document.createElement('div');
        orb.className = 'py-orb';
        orb.innerHTML = logo.replace(/id="g"/g,'id="g2"').replace(/url\(#g\)/g,'url(#g2)');
        root.appendChild(orb);

        const toasts = document.createElement('div');
        toasts.className = 'py-toasts';
        root.appendChild(toasts);
        uiToast = (text, kind) => {
            const el = document.createElement('div');
            el.className = 'py-toast' + (kind ? ' ' + kind : '');
            el.textContent = text;
            toasts.appendChild(el);
            while (toasts.children.length > 4) toasts.firstChild.remove();
            setTimeout(() => { try { el.remove(); } catch {} }, 3200);
        };

        const $ = s => panel.querySelector(s);
        const logEl = $('#py-log');
        uiLog = (msg, kind) => {
            const el = document.createElement('div');
            el.className = 'py-log-line' + (kind && kind !== 'info' ? ` py-log-${kind}` : '');
            el.textContent = msg;
            logEl.appendChild(el);
            logEl.scrollTop = logEl.scrollHeight;
            while (logEl.children.length > 240) logEl.firstChild.remove();
        };
        ui.setStatus = (txt) => { const el = panel.querySelector('#py-status-line'); if (el) el.textContent = txt; };

        // Tabs
        panel.querySelectorAll('.py-tab').forEach(t => t.addEventListener('click', () => {
            panel.querySelectorAll('.py-tab').forEach(x => x.classList.toggle('active', x === t));
            panel.querySelectorAll('.py-content').forEach(c => c.classList.toggle('active', c.dataset.c === t.dataset.t));
        }));

        // Drag
        let pos = { x: Math.max(0, innerWidth - 430), y: 80 };
        let orbPos = { x: Math.max(0, innerWidth - 80), y: 100 };
        try {
            const s = JSON.parse(localStorage.getItem('py316-pos') || 'null');
            if (s?.panel) pos = s.panel;
            if (s?.orb) orbPos = s.orb;
        } catch {}
        const save = () => { try { localStorage.setItem('py316-pos', JSON.stringify({ panel: pos, orb: orbPos })); } catch {} };
        const clampP = (p, w, h) => ({ x: clamp(p.x, 0, innerWidth - w), y: clamp(p.y, 0, innerHeight - h) });
        const applyP = () => { pos = clampP(pos, 400, 440); panel.style.left = pos.x + 'px'; panel.style.top = pos.y + 'px'; };
        const applyO = () => { orbPos = clampP(orbPos, 48, 48); orb.style.left = orbPos.x + 'px'; orb.style.top = orbPos.y + 'px'; };
        applyP(); applyO();
        addEventListener('resize', () => { applyP(); applyO(); });

        const drag = (el, handle, get, set) => {
            let on = false, moved = false, ox = 0, oy = 0, sx = 0, sy = 0;
            handle.addEventListener('pointerdown', e => {
                if (e.button !== 0 || e.target.closest('button,input,textarea,label,.py-toggle,.py-log')) return;
                on = true; moved = false;
                const r = el.getBoundingClientRect();
                ox = e.clientX - r.left; oy = e.clientY - r.top;
                sx = e.clientX; sy = e.clientY;
                try { handle.setPointerCapture(e.pointerId); } catch {}
                e.preventDefault();
            });
            handle.addEventListener('pointermove', e => {
                if (!on) return;
                if (Math.abs(e.clientX - sx) + Math.abs(e.clientY - sy) > 3) moved = true;
                if (!moved) return;
                set({ x: e.clientX - ox, y: e.clientY - oy });
                el.style.left = get().x + 'px'; el.style.top = get().y + 'px';
            });
            const end = e => { if (!on) return; on = false; try { handle.releasePointerCapture(e.pointerId); } catch {} if (moved) save(); };
            handle.addEventListener('pointerup', end);
            handle.addEventListener('pointercancel', end);
            return () => moved;
        };
        drag(panel, panel.querySelector('.py-head'), () => pos, p => { pos = clampP(p, 400, 440); });
        const orbMoved = drag(orb, orb, () => orbPos, p => { orbPos = clampP(p, 48, 48); });

        const setMin = (m) => {
            panel.classList.toggle('hidden', m);
            panel.classList.toggle('visible', !m);
            orb.classList.toggle('visible', m);
            if (m) applyO(); else applyP();
        };
        $('.py-min').addEventListener('click', () => setMin(true));
        orb.addEventListener('click', () => { if (orbMoved()) return; setMin(false); });

        addEventListener('keydown', (e) => {
            if (e.ctrlKey && e.shiftKey && !e.altKey && (e.key === 'P' || e.key === 'p')) {
                e.preventDefault(); e.stopPropagation();
                setMin(!panel.classList.contains('hidden'));
            } else if (e.key === 'Escape' && !panel.classList.contains('hidden')) {
                setMin(true);
            }
        });

        setInterval(() => {
            orb.classList.toggle('active', !!rpcInterval || gameState.active || streamState.active);
        }, 400);

        // RPC
        const nameIn = $('#py-name');
        const rot = $('#py-rot');
        try { const v = localStorage.getItem('py316-name'); if (v) nameIn.value = v; } catch {}
        nameIn.addEventListener('input', () => { try { localStorage.setItem('py316-name', nameIn.value); } catch {} });
        ui.onRpcEnded = () => { rot.checked = false; };

        $('#py-apply').addEventListener('click', () => {
            const n = nameIn.value.trim();
            if (!n) return log('Enter a name', 'warn');
            stopRpc();
            if (applyRpc(n)) log(`RPC → ${n}`, 'success');
            else log('Gateway error', 'error');
        });
        $('#py-stop').addEventListener('click', () => { stopRpc(); rot.checked = false; });
        rot.addEventListener('change', async () => {
            if (rot.checked) {
                rot.disabled = true;
                try { await startRotation(); log('Rotation started', 'success'); }
                catch (e) { log(e.message, 'error'); rot.checked = false; }
                finally { rot.disabled = false; }
            } else stopRpc();
        });

        // Profile
        const act = async (btn, fn, okMsg) => {
            btn.disabled = true;
            try { await fn(); log(okMsg, 'success'); }
            catch (e) { log(e.message, 'error'); }
            finally { btn.disabled = false; }
        };
        $('#py-dname-btn').addEventListener('click', () => act($('#py-dname-btn'), () => changeDisplayName($('#py-dname').value.trim()), 'Display name updated'));
        $('#py-bio-btn').addEventListener('click', () => act($('#py-bio-btn'), () => changeBio($('#py-bio').value), 'Bio saved'));
        $('#py-bio-clr').addEventListener('click', () => act($('#py-bio-clr'), async () => { await changeBio(''); $('#py-bio').value = ''; }, 'Bio cleared'));
        $('#py-pron-btn').addEventListener('click', () => act($('#py-pron-btn'), () => changePronouns($('#py-pron').value.trim()), 'Pronouns set'));
        $('#py-cstat-btn').addEventListener('click', () => act($('#py-cstat-btn'), () => changeCustomStatus($('#py-cstat').value), 'Status applied'));
        $('#py-acc-btn').addEventListener('click', () => act($('#py-acc-btn'), () => changeAccentColor($('#py-acc').value), 'Accent set'));
        panel.querySelectorAll('[data-h]').forEach(b => b.addEventListener('click', () => act(b, () => setHypeSquad(+b.dataset.h), `HypeSquad ${b.dataset.h}`)));
        $('#py-hype-out').addEventListener('click', () => act($('#py-hype-out'), () => setHypeSquad(null), 'Left HypeSquad'));

        // Token
        $('#py-tok-show').addEventListener('click', e => {
            const box = $('#py-tok-box');
            if (box.dataset.on === '1') { box.innerHTML = ''; box.dataset.on = '0'; e.target.textContent = 'Show'; return; }
            const tok = getAuthToken();
            if (!tok) { box.innerHTML = '<div style="color:#ed4245;font-size:11px">Token not found</div>'; return; }
            box.innerHTML = `<div class="py-token">${tok}</div>`;
            const c = document.createElement('button');
            c.className = 'py-btn py-btn-g'; c.style.marginTop = '6px'; c.textContent = 'Copy';
            c.onclick = () => { navigator.clipboard.writeText(tok).then(() => { c.textContent = 'Copied'; setTimeout(() => c.textContent = 'Copy', 900); }); };
            box.appendChild(c);
            box.dataset.on = '1'; e.target.textContent = 'Hide';
        });

        // Tools
        $('#py-ghost').addEventListener('change', e => {
            if (setGhostMode(e.target.checked)) log(e.target.checked ? 'Ghost ON' : 'Ghost OFF', 'success');
            else log('Gateway error', 'error');
        });
        panel.querySelectorAll('[data-s]').forEach(b => b.addEventListener('click', () => {
            if (setStatus(b.dataset.s)) log(`Status → ${b.dataset.s}`, 'success');
            else log('Gateway error', 'error');
        }));
        $('#py-read').addEventListener('click', () => { if (!markAllRead()) log('Module not found', 'error'); });
        $('#py-reset').addEventListener('click', () => {
            if (confirm('Force logout + new token?')) {
                try { localStorage.removeItem('token'); location.reload(); } catch (e) { log(e.message, 'error'); }
            }
        });

        // Forge
        const gh = $('#py-gh'), sh = $('#py-sh');
        try {
            const a = localStorage.getItem('py316-gh'); if (a) gh.value = a;
            const b = localStorage.getItem('py316-sh'); if (b) sh.value = b;
        } catch {}
        gh.onchange = () => { try { localStorage.setItem('py316-gh', gh.value); } catch {} };
        sh.onchange = () => { try { localStorage.setItem('py316-sh', sh.value); } catch {} };

        const runForge = async (btn, fn) => {
            btn.disabled = true; const t = btn.textContent; btn.textContent = 'Running…';
            try { await fn(); } catch (e) { log(e.message, 'error'); }
            finally { btn.disabled = false; btn.textContent = t; }
        };
        $('#py-gstart').addEventListener('click', () => runForge($('#py-gstart'), () => startGameForge(Math.max(1, +gh.value || 4000))));
        $('#py-sstart').addEventListener('click', () => runForge($('#py-sstart'), () => startStreamForge(Math.max(1, +sh.value || 800))));

        $('#py-kill').addEventListener('click', () => {
            stopRpc();
            try { gameState.stop?.(); } catch {}
            try { streamState.stop?.(); } catch {}
            rot.checked = false;
            log('Everything stopped', 'warn');
        });
        $('#py-log-clr').addEventListener('click', () => { logEl.innerHTML = ''; });

        setTimeout(() => {
            load.classList.add('done');
            setTimeout(() => { try { load.remove(); } catch {} setMin(false); }, 700);
        }, 4000);

        log(`${CFG.brand.name} v${CFG.brand.version} ready`, 'success');
    };

    // ==================== UPDATE CHECK ====================
    const checkUpdate = async () => {
        const repo = window.__py316Repo;
        if (!repo) return;
        try {
            const r = await fetch(`${repo}/version.json?t=${Date.now()}`, { cache: 'no-store' });
            if (!r.ok) return;
            const j = await r.json();
            if (j?.version && String(j.version) !== String(__version)) {
                log(`Update available: ${j.version} (current ${__version})`, 'warn');
                ui.setStatus?.(`update ${j.version} ready · v${__version}`);
            }
        } catch {}
    };

    // ==================== BOOT ====================
    try { setupUI(); } catch (e) { try { console.error('[Python3.16] UI error', e); } catch {} }
    checkUpdate();
    (async () => {
        try {
            await ensureContext();
            log(`Welcome ${ctx.globalName}`, 'success');
            ui.setStatus?.(`${ctx.globalName} · v${__version}`);
        } catch (e) {
            log(`Auth: ${e.message}`, 'error');
            ui.setStatus?.(`offline · v${__version}`);
        }
    })();

    window.__python316 = {
        __version,
        applyRpc, stopRpc, startRotation,
        changeBio, changeDisplayName, changePronouns, changeCustomStatus, changeAccentColor, setHypeSquad,
        setStatus, setGhostMode, markAllRead, getAuthToken,
        startGameForge, startStreamForge,
        destroy() {
            stopRpc();
            try { gameState.stop?.(); } catch {}
            try { streamState.stop?.(); } catch {}
            try { document.getElementById('py316-host')?.remove(); } catch {}
            delete window.__python316;
        }
    };
})();
