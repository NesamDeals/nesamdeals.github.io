#!/bin/bash
# TruePick link-info function setup (run inside Google Cloud Shell). It holds NO secrets.
set -e
mkdir -p "$HOME/truepick-fn/functions"
cd "$HOME/truepick-fn"
cat > firebase.json <<'FNEOF'
{
  "functions": [
    {
      "source": "functions",
      "codebase": "default"
    }
  ]
}
FNEOF
cat > .firebaserc <<'FNEOF'
{
  "projects": {
    "default": "nesamdeal"
  }
}
FNEOF
cat > functions/package.json <<'FNEOF'
{
  "name": "truepick-functions",
  "private": true,
  "main": "index.js",
  "engines": { "node": "22" },
  "dependencies": { "firebase-admin": "^12.6.0", "firebase-functions": "^6.0.1" }
}
FNEOF
cat > functions/lib.js <<'FNEOF'
'use strict';
/* Pure helpers (no Firebase dependency) so they can be tested anywhere. */
const UA_BOT='facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)';
const UA_WEB='Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';

function num(v){ if(v==null) return null; const n=parseFloat(String(v).replace(/[^0-9.]/g,'')); return isFinite(n)&&n>0?n:null }
function decode(s){ return String(s||'').replace(/&amp;/g,'&').replace(/&quot;/g,'"').replace(/&#39;|&#x27;/g,"'").replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/\s+/g,' ').trim() }
function metaOf(html,key){
  const re=new RegExp('<meta[^>]+(?:property|name)=["\']'+key.replace(/[.:]/g,'\\$&')+'["\'][^>]*>','i');
  const m=html.match(re); if(!m) return '';
  const c=m[0].match(/content=["']([^"']*)["']/i); return c?decode(c[1]):'';
}
function priceFromJsonLd(html){
  const out={price:null,mrp:null};
  const re=/<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi; let m;
  function walk(x){
    if(!x||typeof x!=='object'||out.price) return;
    if(Array.isArray(x)){ x.forEach(walk); return }
    if(x.offers){
      const o=Array.isArray(x.offers)?x.offers[0]:x.offers;
      if(o){ const p=num(o.price||o.lowPrice||(o.priceSpecification&&o.priceSpecification.price)); if(p){ out.price=p; const h=num(o.highPrice); if(h&&h>p) out.mrp=h; return } }
    }
    Object.keys(x).forEach(k=>{ if(k!=='offers') walk(x[k]) });
  }
  while((m=re.exec(html))){ try{ walk(JSON.parse(m[1])) }catch(e){} }
  return out;
}
function parseHtml(html,base){
  html=String(html||'');
  let title=metaOf(html,'og:title')||metaOf(html,'twitter:title');
  if(!title){ const t=html.match(/<title[^>]*>([\s\S]*?)<\/title>/i); if(t) title=decode(t[1]) }
  let image=metaOf(html,'og:image')||metaOf(html,'twitter:image');
  if(image){ try{ image=new URL(image,base).href.replace(/^http:\/\//,'https://') }catch(e){ image='' } }
  const desc=(metaOf(html,'og:description')||metaOf(html,'description')).slice(0,300);
  let price=num(metaOf(html,'product:price:amount')||metaOf(html,'og:price:amount'));
  let mrp=null;
  const ld=priceFromJsonLd(html); if(!price&&ld.price){ price=ld.price; mrp=ld.mrp }
  return {title,image,desc,price,mrp};
}
function cleanTitle(t){
  return String(t||'').replace(/^Amazon\.in\s*:\s*/i,'').replace(/\s*[:|-]\s*Amazon\.in.*$/i,'').replace(/\s+/g,' ').trim().slice(0,140);
}
function junkTitle(t){
  t=String(t||'').trim(); if(t.length<6) return true;
  if(/^[A-Za-z0-9]{8,14}$/.test(t)) return true;
  return /robot check|access denied|just a moment|captcha|are you a human|page not found|sorry|^amazon(\.in)?$|^404|error/i.test(t);
}
function asinFrom(url){
  let u; try{ u=new URL(url) }catch(e){ return '' }
  if(!/amazon|amzn/i.test(u.hostname)) return "";
  const m=u.pathname.match(/\/(?:dp|gp\/product|gp\/aw\/d|d|product)\/([A-Za-z0-9]{10})(?:[/?]|$)/);
  if(m) return m[1].toUpperCase();
  const last=u.pathname.split('/').filter(Boolean).pop()||'';
  if(/^[A-Za-z0-9]{10}$/.test(last)&&/^B0/i.test(last)) return last.toUpperCase();
  return '';
}
function isAmazonHost(url){ try{ return /(^|\.)(amazon\.[a-z.]+|amzn\.to|amzn\.in|link\.amazon|a\.co)$/i.test(new URL(url).hostname) }catch(e){ return false } }
function storeOf(url){
  let h=''; try{ h=new URL(url).hostname.toLowerCase() }catch(e){}
  return /amazon|amzn|a\.co$/.test(h)?'Amazon':/meesho/.test(h)?'Meesho':/flipkart|fkrt/.test(h)?'Flipkart':/myntra/.test(h)?'Myntra':'';
}
function parseAmazon(j,asin){
  const items=(j&&((j.itemsResult&&j.itemsResult.items)||(j.itemResults&&j.itemResults.items)))||[];
  const it=items.find(x=>x&&String(x.asin).toUpperCase()===asin)||items[0]; if(!it) return null;
  const info=it.itemInfo||{};
  const title=cleanTitle(info.title&&info.title.displayValue);
  const image=(it.images&&it.images.primary&&it.images.primary.large&&it.images.primary.large.url)||'';
  const feats=(info.features&&info.features.displayValues)||[];
  const pg=(info.classifications&&info.classifications.productGroup&&info.classifications.productGroup.displayValue)||'';
  const l=(it.offersV2&&Array.isArray(it.offersV2.listings)&&it.offersV2.listings[0])||null;
  let price=null,mrp=null;
  if(l&&l.price){
    price=num(l.price.money&&l.price.money.amount);
    const b=num(l.price.savingBasis&&l.price.savingBasis.money&&l.price.savingBasis.money.amount);
    if(price&&b&&b>price) mrp=b;
  }
  return {title,image,price,mrp,desc:(pg+' '+feats.slice(0,3).join(' ')).trim().slice(0,300),hint:pg};
}
module.exports={UA_BOT,UA_WEB,num,parseHtml,cleanTitle,junkTitle,asinFrom,isAmazonHost,storeOf,parseAmazon};
FNEOF
cat > functions/index.js <<'FNEOF'
'use strict';
const functions=require('firebase-functions/v1');
const admin=require('firebase-admin');
const L=require('./lib');
admin.initializeApp();

/* Only the account typed during setup (saved in functions/.env as OWNER_EMAIL) may call this function. */
const ORIGIN='https://nesamdeals.github.io';
const TAG='offersshopp02-21';                   /* your Amazon India tracking id */
const MKT='www.amazon.in';
const TOKEN_URL='https://api.amazon.co.uk/auth/o2/token';   /* credential version 3.2 (EU/India) */
const API='https://creatorsapi.amazon/catalog/v1/getItems';

let tok={v:'',exp:0};
async function amazonToken(){
  if(tok.v&&Date.now()<tok.exp) return tok.v;
  const r=await fetch(TOKEN_URL,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({grant_type:'client_credentials',client_id:process.env.CREATORS_ID,client_secret:process.env.CREATORS_SECRET,scope:'creatorsapi::default'})});
  const j=await r.json().catch(()=>({}));
  if(!j.access_token) throw new Error('token '+r.status+' '+JSON.stringify(j).slice(0,200));
  tok={v:j.access_token,exp:Date.now()+Math.max(60,(j.expires_in||3600)-120)*1000};
  return tok.v;
}
async function amazonItem(asin){
  const tk=await amazonToken();
  async function call(resources,auth){
    const r=await fetch(API,{method:'POST',headers:{'Authorization':auth,'Content-Type':'application/json','x-marketplace':MKT},body:JSON.stringify({itemIds:[asin],itemIdType:'ASIN',marketplace:MKT,partnerTag:TAG,resources})});
    return {ok:r.ok,status:r.status,j:await r.json().catch(()=>({}))};
  }
  const full=['itemInfo.title','itemInfo.features','itemInfo.classifications','images.primary.large','offersV2.listings.price'];
  const min=['itemInfo.title','images.primary.large','offersV2.listings.price'];
  let a='Bearer '+tk;
  let r=await call(full,a);
  if(!r.ok&&(r.status===401||r.status===403)){ a='Bearer '+tk+', Version 3.2'; r=await call(full,a) }
  if(!r.ok&&r.status===400) r=await call(min,a);
  if(!r.ok) throw new Error('amazon '+r.status+' '+JSON.stringify(r.j).slice(0,300));
  const p=L.parseAmazon(r.j,asin);
  if(!p) throw new Error('amazon no item '+JSON.stringify(r.j).slice(0,300));
  return p;
}
/* follow redirects by hand so short links (amzn.to, link.amazon, meesho.io ...) resolve to the real address */
async function resolve(url){
  let u=url;
  for(let i=0;i<6;i++){
    let r; try{ r=await fetch(u,{method:'GET',redirect:'manual',headers:{'User-Agent':L.UA_WEB},signal:AbortSignal.timeout(8000)}) }catch(e){ break }
    const loc=r.headers.get('location');
    if(r.status>=300&&r.status<400&&loc){ try{ u=new URL(loc,u).href }catch(e){ break } } else break;
  }
  return u;
}
async function page(url){
  let best=null;
  for(const ua of [L.UA_BOT,L.UA_WEB]){
    try{
      const r=await fetch(url,{redirect:'follow',headers:{'User-Agent':ua,'Accept':'text/html,application/xhtml+xml','Accept-Language':'en-IN,en;q=0.9'},signal:AbortSignal.timeout(12000)});
      const html=(await r.text()).slice(0,900000);
      const p=L.parseHtml(html,r.url||url); p.title=L.cleanTitle(p.title);
      if(L.junkTitle(p.title)) p.title='';
      best=Object.assign({},best||{},Object.fromEntries(Object.entries(p).filter(([k,v])=>v&&!(best&&best[k]))));
      if(best.title&&best.image&&best.price) break;
    }catch(e){}
  }
  return best||{};
}
async function handler(req,res){
  res.set('Access-Control-Allow-Origin',ORIGIN);
  res.set('Access-Control-Allow-Headers','Authorization, Content-Type');
  res.set('Access-Control-Allow-Methods','POST, OPTIONS');
  res.set('Vary','Origin');
  if(req.method==='OPTIONS') return res.status(204).send('');
  if(req.method!=='POST') return res.status(405).json({ok:false,error:'method'});
  try{
    const owner=String(process.env.OWNER_EMAIL||'').trim().toLowerCase();
    const m=String(req.get('Authorization')||'').match(/^Bearer (.+)$/);
    if(!m) return res.status(401).json({ok:false,error:'no token'});
    const d=await admin.auth().verifyIdToken(m[1]);
    if(!owner||String(d.email||'').toLowerCase()!==owner||d.email_verified!==true) return res.status(403).json({ok:false,error:'not allowed'});
  }catch(e){ return res.status(401).json({ok:false,error:'bad token'}) }
  const url=String((req.body&&req.body.url)||'').trim();
  if(!/^https:\/\/[^\s]{4,1000}$/.test(url)) return res.status(400).json({ok:false,error:'bad url'});
  const out={ok:false,store:'',title:'',image:'',price:null,mrp:null,desc:'',via:'',note:''};
  try{
    const fin=await resolve(url);
    out.store=L.storeOf(fin)||L.storeOf(url);
    if(L.isAmazonHost(fin)||L.isAmazonHost(url)){
      const asin=L.asinFrom(fin)||L.asinFrom(url);
      if(asin){
        try{ Object.assign(out,await amazonItem(asin),{via:'amazon-api'}); out.store='Amazon' }
        catch(e){ out.note=String(e.message||e).slice(0,400) }
      } else out.note='no asin';
    }
    if(!out.title||!out.image||!out.price){
      const p=await page(fin);
      ['title','image','desc','price','mrp'].forEach(k=>{ if(!out[k]&&p[k]) out[k]=p[k] });
      if(!out.via&&(p.title||p.image||p.price)) out.via='page';
    }
    out.ok=!!(out.title||out.image||out.price);
  }catch(e){ out.note=String(e.message||e).slice(0,300) }
  res.status(200).json(out);
}
exports.linkInfo=functions.region('asia-south1').runWith({secrets:['CREATORS_ID','CREATORS_SECRET'],timeoutSeconds:40,memory:'256MB'}).https.onRequest(handler);
FNEOF

echo
read -r -p "Type your Google email (the one you use for the admin panel): " OWNER_EMAIL_IN
printf 'OWNER_EMAIL=%s\n' "$OWNER_EMAIL_IN" > functions/.env
(cd functions && npm install --no-audit --no-fund)
command -v firebase >/dev/null 2>&1 || npm install -g firebase-tools
firebase login --no-localhost
echo
echo "Now paste your NEW Amazon Credential ID, press Enter."
firebase functions:secrets:set CREATORS_ID --project nesamdeal
echo "Now paste your NEW Amazon Credential Secret, press Enter."
firebase functions:secrets:set CREATORS_SECRET --project nesamdeal
firebase deploy --only functions --project nesamdeal --force
echo
echo "DONE. Function address: https://asia-south1-nesamdeal.cloudfunctions.net/linkInfo"
