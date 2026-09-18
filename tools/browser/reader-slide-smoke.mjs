// Chromium/CDP against the real reader, synthetic archives, and GET-only owner assets.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { chromium } from 'playwright-core';
import { expect } from '@playwright/test';
const root = resolve(import.meta.dirname, '../..');
const owner = process.env.LRR_DEPLOY_BASE_URL;
assert.ok(owner, 'LRR_DEPLOY_BASE_URL required');
const archive = 'e'.repeat(40);
const errors = [], receipts = [];
let webtoon = false;
let tank = false;
let tall = false;
const server = createServer(async (req, res) => {
    const url = new URL(req.url, 'http://fixture');
    const json = value => { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(value)); };
    try {
        if (url.pathname === '/fixture/page') {
            const i = Number.parseInt(url.searchParams.get('path'));
            res.setHeader('Content-Type', 'image/svg+xml');
            return res.end(`<svg xmlns="http://www.w3.org/2000/svg" width="${i % 3 === 0 ? 260 : 280}" height="${tall?1200:400}"><rect width="100%" height="100%" fill="${['#dd5555','#55cc99','#6699ee'][i%3]}"/><text x="60" y="100" font-size="60">${i}</text></svg>`);
        }
        if (!['GET','HEAD'].includes(req.method)) return json({ success: true });
        if (url.pathname.endsWith('/full')) return json({result:{name:'Tank fixture',progress:1,full_data:[{arcid:archive,title:'First',pagecount:8},{arcid:'d'.repeat(40),title:'Second',pagecount:8}]}});
        if (url.pathname.endsWith('/metadata')) return json({ id:archive,title:'Slide fixture',pagecount:16,progress:1,tags:webtoon?'webtoon':'',summary:'',extension:'cbz',spreadstart:'pair2',firstspreadstart:'2',adaptiveoffset_enabled:0 });
        if (url.pathname.endsWith('/files')) return json({ pages:Array.from({length:tank?8:16},(_,i)=>`/fixture/page?path=${i+(tank&&url.pathname.includes('d'.repeat(40))?8:0)}.svg`) });
        if (url.pathname.startsWith('/api/')) return json([]);
        const local = url.pathname.match(/^\/(js)\/(?:[^/]+\/)?(mod\/[^/]+\.js)$/) || url.pathname.match(/^\/(js|css)\/(?:[^/]+\/)?([^/]+\.(?:js|css))$/);
        if (local && process.env.LRR_SLIDE_LIVE !== '1' && !url.pathname.includes('/vendor/')) {
            const bytes = await readFile(resolve(root, 'public', local[1], local[2])).catch(()=>null);
            if (bytes) { res.setHeader('Content-Type',local[1]==='js'?'text/javascript':'text/css'); return res.end(bytes); }
        }
        if (!(url.pathname === '/reader' || /^\/(js|css|themes|images|webfonts|fonts|favicon)/.test(url.pathname))) { res.statusCode=404;return res.end(); }
        const upstream = await fetch(new URL(req.url, owner));
        res.setHeader('Content-Type', upstream.headers.get('content-type') || 'text/plain');
        let bytes = Buffer.from(await upstream.arrayBuffer());
        if (url.pathname === '/reader' && process.env.LRR_SLIDE_LIVE !== '1') {
            let html = bytes.toString();
            if (!html.includes('"lrr-reader-slide":')) {
                for (const suffix of ['', '-controller', '-motion']) html=html.replace('"lrr-reader-display":',`"lrr-reader-slide${suffix}": "/js/mod/reader-slide${suffix}.js", "lrr-reader-display":`);
            }
            const template = await readFile(resolve(root,'templates/reader.html.tt2'),'utf8');
            const settings = template.match(/<div id="page-slide-settings">[\s\S]*?(?=<div id="toggle-infinite-scroll">)/)[0]
                .replace(/\[% c\.lh\("([^"]*)"\) %\]/g,'$1');
            if (!html.includes('id="page-slide-settings"')) {
                html=html.replace('<div id="toggle-infinite-scroll">', settings+'<div id="toggle-infinite-scroll">');
            }
            bytes=Buffer.from(html);
        }
        res.end(bytes);
    } catch(error) { errors.push(error.message); res.statusCode=502; res.end('fixture unavailable'); }
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const base=`http://127.0.0.1:${server.address().port}`;
const browser=await chromium.launch({headless:true});
const animations=page=>page.evaluate(()=>document.getAnimations().filter(a=>a.id.startsWith('reader-page-')).map(a=>({id:a.id,duration:a.effect.getTiming().duration,easing:a.effect.getTiming().easing})));
const visible=page=>page.locator('#img').getAttribute('data-filename');
async function open({double=false,rtl=false,continuous=false,enabled=true,reduced=false,mobile=false}={}) {
    const context=await browser.newContext({hasTouch:true,isMobile:mobile,viewport:mobile?{width:390,height:844}:{width:1000,height:700},reducedMotion:reduced?'reduce':'no-preference'});
    const page=await context.newPage();
    page.on('pageerror',e=>errors.push(e.message));
    await page.addInitScript(settings=>{if(!localStorage.slideFixtureInitialized){Object.assign(localStorage,settings);localStorage.slideFixtureInitialized='true';}},{doublePageMode:String(double),mangaMode:String(rtl),infiniteScroll:String(continuous),slidePages:String(enabled),slideDuration:'1000',hideHeader:'true',mobileFullscreen:'false',ignoreProgress:'true',showOverlayByDefault:'false',fitMode:continuous?'fit-width':'fit-height',spreadStart:'pair2'});
    await page.goto(`${base}/reader?id=${tank?"TANK_fixture":archive}&p=5`,{waitUntil:'networkidle'});
    await expect(page.locator(continuous?'#page-4':'#img')).toBeVisible();
    return {page,context};
}
async function touch(page,points,{cancel=false,hold=100,inspect}={}) {
    const cdp=await page.context().newCDPSession(page);
    await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x:points[0][0],y:points[0][1]}]});
    for(const [x,y] of points.slice(1)) {
        await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x,y}]});
        await page.waitForTimeout(25);
    }
    if(inspect) await inspect();
    if(hold) await page.waitForTimeout(hold);
    await cdp.send('Input.dispatchTouchEvent',{type:cancel?'touchCancel':'touchEnd',touchPoints:[]});
    await cdp.detach();
}
try {
    for(const double of [false,true]) for(const rtl of [false,true]) {
        const {page,context}=await open({double,rtl});
        await expect(page.locator('#display')).toHaveAttribute('data-reader-swipe','');
        const initial=await visible(page);
        await page.keyboard.press(rtl?'ArrowLeft':'ArrowRight');
        await expect.poll(()=>visible(page)).not.toBe(initial);
        assert.ok((await animations(page)).some(a=>a.id==='reader-page-slide'&&a.duration===1000));
        // Freeze all tracks at the same time and compare adjacent boundaries.
        const geometry=await page.evaluate(()=>{
            const all=document.getAnimations().filter(a=>a.id.startsWith('reader-page-slide'));
            for(const a of all) { a.pause();a.currentTime=0; }
            const rect=a=>{const r=a.effect.target.getBoundingClientRect();return {left:r.left,right:r.right,width:r.width};};
            return {incoming:all.filter(a=>a.id==='reader-page-slide').map(rect),outgoing:all.filter(a=>a.id==='reader-page-slide-outgoing').map(rect)};
        });
        assert.ok(geometry.incoming.length && geometry.outgoing.length);
        assert.ok([...geometry.incoming,...geometry.outgoing].every(r=>r.width>0));
        const gap=rtl?Math.min(...geometry.outgoing.map(r=>r.left))-Math.max(...geometry.incoming.map(r=>r.right))
            :Math.min(...geometry.incoming.map(r=>r.left))-Math.max(...geometry.outgoing.map(r=>r.right));
        assert.ok(Math.abs(gap)<2,`first-frame gap ${gap}`);
        const beforeReverse=await page.evaluate(()=>{
            const all=document.getAnimations();all.forEach(a=>{a.pause();a.currentTime=100;});
            window.reversalImage=all.find(a=>a.id==='reader-page-slide-outgoing').effect.target;
            return window.reversalImage.getBoundingClientRect().left;
        });
        await page.keyboard.press(rtl?'ArrowRight':'ArrowLeft');
        await expect.poll(()=>visible(page)).toBe(initial);
        const afterReverse=await page.evaluate(()=>{
            document.getAnimations().forEach(a=>{a.pause();a.currentTime=0;});
            const left=window.reversalImage.getBoundingClientRect().left;
            document.getAnimations().forEach(a=>a.play());return left;
        });
        assert.ok(Math.abs(beforeReverse-afterReverse)<2,'reversal preserves rendered position');
        await page.waitForTimeout(1100);
        // Forward-back-forward must reuse the same decoded image node.
        await page.evaluate(()=>{window.retainedReaderImage=document.getElementById('img');});
        await page.keyboard.press(rtl?'ArrowLeft':'ArrowRight');
        await expect.poll(()=>visible(page)).not.toBe(initial);
        await page.keyboard.press(rtl?'ArrowRight':'ArrowLeft');
        await expect.poll(()=>visible(page)).toBe(initial);
        assert.ok(await page.evaluate(()=>window.retainedReaderImage===document.getElementById('img')));
        await page.waitForTimeout(1100);
        const sign=rtl?1:-1;
        await touch(page,[[500,350],[500+sign*30,350],[500+sign*100,350],[500+sign*230,350]],{hold:0,inspect:async()=>{
            const preview=await page.evaluate(()=>document.getAnimations().filter(a=>a.id==='reader-page-drag').map(a=>{
                const r=a.effect.target.getBoundingClientRect();return {left:r.left,right:r.right,width:r.width};
            }).sort((a,b)=>a.left-b.left));
            assert.ok(preview.length>=(double?6:3),'both decoded neighbors follow touch');
            for(let i=1;i<preview.length;i++) assert.ok(Math.abs(preview[i].left-preview[i-1].right)<2,'preview edges touch');
        }});
        await expect.poll(()=>visible(page)).not.toBe(initial);
        assert.ok((await animations(page)).some(a=>a.easing==='linear'));
        await page.waitForTimeout(1400);
        const after=await visible(page);
        assert.equal(Number.parseInt(after),Number.parseInt(initial)+(double?2:1),"one page turn per touch");
        await touch(page,[[500,350],[520,350],[530,350]],{cancel:true});
        await page.waitForTimeout(1500);
        assert.equal(await visible(page),after);
        await touch(page,[[500,350],[520,350],[530,350]]);
        await page.waitForTimeout(1500);
        assert.equal(await visible(page),after);
        await page.keyboard.press(rtl?'ArrowLeft':'ArrowRight');
        await page.setViewportSize({width:990,height:700});
        await expect.poll(()=>animations(page)).toEqual([]);
        receipts.push({double,rtl,firstFrameGap:gap,touch:'flick/cancel/short drag',keyboard:'forward/reversal/resize'});
        await context.close();
    }
    for(const scenario of ['disabled','reduced']) {
        const {page,context}=await open({enabled:scenario!=='disabled',reduced:scenario==='reduced'});
        await page.keyboard.press('ArrowRight');
        await page.waitForTimeout(100);
        assert.deepEqual(await animations(page),[]);
        await expect(page.locator('.reader-slide-effects')).toHaveCount(0);
        receipts.push({scenario,passed:true});await context.close();
    }
    for(const tagged of [false,true]) {
        webtoon=tagged;
        const {page,context}=await open({continuous:true,mobile:true});
        await page.evaluate(()=>{
            window.scrollWrites=0;
            for(const [obj,key] of [[window,'scrollTo'],[window,'scrollBy'],[Element.prototype,'scrollIntoView'],[Element.prototype,'scrollTo']]) {
                const original=obj[key];obj[key]=function(...args){window.scrollWrites++;return original.apply(this,args);};
            }
        });
        const before=await page.evaluate(()=>scrollY);
        for(let i=0;i<3;i++) await touch(page,[[195,700],[195,650],[195,550],[195,450],[195,250]],{hold:140});
        assert.ok(await page.evaluate(()=>scrollY)>before+500);
        assert.equal(await page.evaluate(()=>window.scrollWrites),0);
        await expect(page.locator('.reader-slide-effects')).toHaveCount(0);
        await page.evaluate(()=>document.getElementById('fit-height').click());
        assert.ok(await page.evaluate(()=>window.scrollWrites)>0);
        receipts.push({continuous:true,webtoon:tagged,scrollWrites:0,layoutCorrection:true});await context.close();
    }
    webtoon=false;
    {
        const {page,context}=await open({enabled:false});
        await page.evaluate(()=>{delete localStorage.slideDuration;});
        await page.reload({waitUntil:'networkidle'});
        await page.evaluate(()=>document.querySelector('.toggle-settings-overlay').click());
        await expect(page.locator('#slide-duration')).toBeDisabled();
        await expect(page.locator('#slide-duration')).toHaveValue('200');
        await page.locator('#slide-pages').check();
        await page.locator('#slide-duration').focus();
        await page.keyboard.press('ArrowRight');
        await expect(page.locator('#slide-duration')).toHaveValue('225');
        await page.reload({waitUntil:'networkidle'});
        await expect(page.locator('#slide-pages')).toBeChecked();
        await expect(page.locator('#slide-duration')).toHaveValue('225');
        await expect(page.locator('#slide-duration')).toBeEnabled();
        receipts.push({settings:'default/off/225ms/reload',passed:true});
        // Cross archive boundaries using the real navigation list and full page lifecycle.
        const next='d'.repeat(40);
        await page.evaluate(ids=>{localStorage.currArchiveIds=JSON.stringify(ids);sessionStorage.navigationState='datatables';},[archive,next]);
        await page.goto(`${base}/reader?id=${archive}&p=16`,{waitUntil:'networkidle',referer:base+'/'});
        await page.keyboard.press('ArrowRight');
        await page.waitForURL(`**/reader?id=${next}*`);
        await page.waitForLoadState('networkidle');
        await page.keyboard.press('ArrowLeft');
        await page.waitForURL(`**/reader?id=${archive}*`);
        await page.waitForLoadState('networkidle');
        receipts.push({archiveBoundary:'forward/back',passed:true});
        await context.close();
    }
    {
        const {page,context}=await open({mobile:true});
        const initial=await visible(page);
        const cdp=await context.newCDPSession(page);
        await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x:160,y:400,id:1},{x:230,y:400,id:2}]});
        await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x:120,y:400,id:1},{x:270,y:400,id:2}]});
        await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
        assert.equal(await visible(page),initial);
        await cdp.send('Input.synthesizePinchGesture',{x:195,y:400,scaleFactor:1.5,relativeSpeed:800,gestureSourceType:'touch'});
        assert.ok(await page.evaluate(()=>visualViewport.scale)>1,'native pinch zoom');
        assert.equal(await page.evaluate(()=>getComputedStyle(document.getElementById('display')).touchAction),'pan-y pinch-zoom');
        tall=true;
        await page.evaluate(()=>{localStorage.hideHeader='false';localStorage.fitMode='fit-width';});
        await page.reload({waitUntil:'networkidle'});
        await expect(page.locator('#display')).not.toHaveAttribute('data-reader-swipe','');
        const before=await page.evaluate(()=>scrollY);
        await touch(page,[[195,700],[195,600],[195,450],[195,250]],{hold:140});
        assert.ok(await page.evaluate(()=>scrollY)>before+100);
        assert.equal(await visible(page),initial);
        receipts.push({pinch:'no page turn',largeImage:'native vertical scroll',passed:true});
        await context.close();
    }
    tall=false;
    tank=true;
    {
        const {page,context}=await open();
        await page.evaluate(async()=>{const reader=await import('lrr-reader-common');await reader.goToPage(7);});
        await page.keyboard.press('ArrowRight');
        await expect.poll(()=>visible(page)).toBe('8.svg');
        assert.deepEqual(await animations(page),[]);
        await page.keyboard.press('ArrowLeft');
        await expect.poll(()=>visible(page)).toBe('7.svg');
        assert.deepEqual(await animations(page),[]);
        receipts.push({tankChapter:'forward/back cleanup',passed:true});
        await context.close();
    }
    console.log(JSON.stringify({receipts,errors},null,2));
    assert.deepEqual(errors,[]);
} finally { await browser.close();server.close(); }
