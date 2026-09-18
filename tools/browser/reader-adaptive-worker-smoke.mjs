// Actual reader modules and keyboard events; synthetic API/images only.
// The optional owner base supplies GET-only HTML/static assets through localhost.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';
import { createHash } from 'node:crypto';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const owner = process.env.LRR_DEPLOY_BASE_URL;
assert.ok(owner, 'LRR_DEPLOY_BASE_URL is required for GET-only template/static assets');
const archive = 'e'.repeat(40), revision = 'a'.repeat(64);
let delayMs = 700, requests = 0;
const writes = [], proxyGets = [], localModules = {};
const rawState = { archiveId: archive, contentRevision: revision, status: 'ready', first_spread_start: 'UNKNOWN',
    segments: [{ archiveId: archive, contentRevision: revision, segmentStart: 2, segmentEnd: 12,
        firstPairStart: 3, boundary: 'until_next_wide', provenance: 'detector' }] };
const server = createServer(async (req, res) => {
    const u = new URL(req.url, 'http://fixture');
    const json = value => { res.setHeader('Content-Type','application/json');res.end(JSON.stringify(value)); };
    try {
        if (u.pathname.startsWith('/fixture/')) {
            const index = Number.parseInt(u.searchParams.get('path'));
            const wide = [0,1,6].includes(index);
            res.setHeader('Content-Type','image/svg+xml');
            return res.end(`<svg xmlns="http://www.w3.org/2000/svg" width="${wide?420:280}" height="400"><rect width="100%" height="100%" fill="#eee"/><text x="40" y="100" font-size="50">${index}</text></svg>`);
        }
        if (!['GET','HEAD'].includes(req.method)) { writes.push(u.pathname); return json({success:true}); }
        if (u.pathname.endsWith('/metadata')) return json({id:archive,title:'Synthetic adaptive test',pagecount:12,progress:1,tags:'',summary:'',extension:'cbz',spreadstart:'auto',firstspreadstart:'4',firstspreadstart_reason:'legacy',adaptiveoffset_enabled:1});
        if (u.pathname.endsWith('/files')) return json({pages:Array.from({length:12},(_,i)=>`/fixture/page?path=${i}.svg`)});
        if (u.pathname.endsWith('/adaptiveoffset')) {
            requests++;
            await new Promise(r=>setTimeout(r,delayMs));
            return json(rawState);
        }
        if (u.pathname.startsWith('/api/')) return json([]);
        const modulePath = u.pathname.match(/^\/js\/(?:[^/]+\/)?mod\/(.+)$/);
        if (modulePath) {
            const file = resolve(root,'public/js/mod',modulePath[1]);
            assert.ok(file.startsWith(resolve(root,'public/js/mod')+'/'));
            if (await stat(file).catch(()=>null)) { const bytes=await readFile(file);localModules[modulePath[1]]=createHash('sha256').update(bytes).digest('hex');res.setHeader('Content-Type','text/javascript'); return res.end(bytes); }
        }
        if (!['/reader','/favicon.ico'].includes(u.pathname) && !/^\/(?:js|css|webfonts|fonts|images|vendor)\//.test(u.pathname)) {
            res.statusCode=404; return res.end();
        }
        proxyGets.push(u.pathname);
        const upstream = await fetch(new URL(req.url,owner),{redirect:'error'});
        res.statusCode=upstream.status;
        res.setHeader('Content-Type',upstream.headers.get('content-type')||'application/octet-stream');
        res.end(Buffer.from(await upstream.arrayBuffer()));
    } catch (e) { res.statusCode=502; res.end('fixture unavailable'); console.error(e.message); }
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const base=`http://127.0.0.1:${server.address().port}`;
const browser=await chromium.launch({headless:true});
const traces=[];
try {
    const page=await browser.newPage({viewport:{width:1440,height:1000}});
    const errors=[];
    page.on('pageerror',e=>errors.push(e.message));
    await page.addInitScript(()=>{localStorage.doublePageMode='true';localStorage.infiniteScroll='false';localStorage.mangaMode='false';localStorage.hideHeader='true';localStorage.mobileFullscreen='false';localStorage.ignoreProgress='true';localStorage.showOverlayByDefault='false';});
    const visible=()=>page.locator('#display .reader-image').evaluateAll(xs=>xs.filter(x=>x.getBoundingClientRect().width>0&&x.getBoundingClientRect().height>0).map(x=>x.dataset.filename).filter(Boolean).sort());
    const expectPages=async(names)=>{
        await page.waitForFunction(expected=>JSON.stringify([...document.querySelectorAll('#display .reader-image')].filter(x=>x.getBoundingClientRect().width>0&&x.getBoundingClientRect().height>0).map(x=>x.dataset.filename).filter(Boolean).sort())===JSON.stringify(expected),names,{timeout:10000}).catch(async(error)=>{console.log(JSON.stringify({expected:names,visible:await visible(),errors,requests,proxyGets,dom:await page.evaluate(()=>({labels:[...document.querySelectorAll('.current-page')].map(e=>e.textContent),reader:typeof window.Reader,images:[...document.querySelectorAll('#display img')].map(e=>({id:e.id,filename:e.dataset.filename,complete:e.complete,width:e.naturalWidth,display:getComputedStyle(e).display}))}))}));throw error;});
        traces.push(await visible());
    };
    await page.goto(`${base}/reader?id=${archive}&p=3`,{waitUntil:'domcontentloaded'});
    await expectPages(['2.svg','3.svg']);
    await expectPages(['2.svg']);
    await page.keyboard.press('ArrowRight');await expectPages(['3.svg','4.svg']);
    await page.keyboard.press('ArrowRight');await expectPages(['5.svg']);
    await page.keyboard.press('ArrowLeft');await expectPages(['3.svg','4.svg']);
    await page.keyboard.press('ArrowRight');await expectPages(['5.svg']);
    await page.keyboard.press('ArrowRight');await expectPages(['6.svg']);
    await page.keyboard.press('ArrowRight');await expectPages(['7.svg','8.svg']);
    // A manual slide cancels a delayed result; no automatic regrouping afterward.
    delayMs=2000;
    await page.goto(`${base}/reader?id=${archive}&p=3`,{waitUntil:'domcontentloaded'});
    await expectPages(['2.svg','3.svg']);
    await page.keyboard.press('ArrowDown');await expectPages(['3.svg','4.svg']);
    await page.waitForTimeout(2200);
    assert.deepEqual(await visible(),['3.svg','4.svg']);
    assert.deepEqual(errors,[]);
    assert.ok(requests>=2);
    console.log(JSON.stringify({passed:true,kind:'synthetic reader keyboard trace',traces,worker_requests:requests,local_modules:localModules,upstream_get_only:true,local_intercepted_writes:writes.length,page_errors:errors}));
} finally { await browser.close(); await new Promise(r=>server.close(r)); }
