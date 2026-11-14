// Revises a COPY of MIRPG-Remote-UI-Review.fig into an editable inspiration study.
// Run using: Get-Content ... -Raw | openpencil eval <new-fig> --stdin -w
// This keeps the user's original five-screen review untouched.
const page = figma.currentPage;
page.name = 'MIRPG Remote / SwiftDesk-inspired V2 / 2026-10-12';
const C = { bg:'#0E151A', surface:'#19262C', raised:'#223238', deep:'#122F2A',
 mint:'#70D8C1', pale:'#C7F7EB', ink:'#F1F4F5', muted:'#9BB4BA',
 outline:'#3B5559', divider:'#2C4549', blue:'#173D50', forest:'#3B7766',
 light:'#E5F0F1', warm:'#EAC98B', warn:'#433A2C'};
function rgb(h) { h=h.replace('#','');return {r:parseInt(h.slice(0,2),16)/255,g:parseInt(h.slice(2,4),16)/255,b:parseInt(h.slice(4,6),16)/255}; }
function paint(h) { return [{type:'SOLID',color:rgb(h)}]; }
const regular={family:'Inter',style:'Regular'}, bold={family:'Inter',style:'Bold'};
await figma.loadFontAsync(regular); await figma.loadFontAsync(bold);
function box(parent,name,x,y,w,h,color,r=0,border=null) {
 const n=figma.createFrame(); parent.appendChild(n);n.name=name;n.resize(w,h);n.x=x;n.y=y;
 n.fills=color?paint(color):[];n.cornerRadius=r;n.clipsContent=true;
 if(border){n.strokes=paint(border);n.strokeWeight=1;}return n;
}
function shape(parent,name,x,y,w,h,color,r=0,border=null){
 const n=figma.createRectangle();parent.appendChild(n);n.name=name;n.resize(w,h);n.x=x;n.y=y;
 n.fills=color?paint(color):[];n.cornerRadius=r;
 if(border){n.strokes=paint(border);n.strokeWeight=1;}return n;
}
function label(parent,name,value,x,y,w,h,size=14,color=C.ink,strong=false,align='LEFT'){
 const n=figma.createText();parent.appendChild(n);n.name=name;n.fontName=strong?bold:regular;
 n.characters=value;n.fontSize=size;n.fills=paint(color);n.textAutoResize='NONE';n.resize(w,h);
 n.x=x;n.y=y;n.textAlignHorizontal=align;n.textAlignVertical='CENTER';return n;
}
function circle(parent,name,x,y,d,color){const n=figma.createEllipse();parent.appendChild(n);n.name=name;n.resize(d,d);n.x=x;n.y=y;n.fills=paint(color);return n;}
function badge(parent,name,value,x,y,w,chosen=false){const b=box(parent,name,x,y,w,30,chosen?C.deep:C.raised,15,chosen?C.mint:C.outline);label(b,'Status',value,6,0,w-12,30,11,chosen?C.mint:C.muted,true,'CENTER');return b;}
function updateText(parent,name,value,sz=null){const n=parent.findOne(n=>n.type==='TEXT'&&n.name===name);if(n){n.fontName=bold;n.characters=value;if(sz)n.fontSize=sz;}return n;}

// Retain fully editable original five artboards; refine the language, styling,
// and hierarchy around the confirmed reference apps.
for (const screen of page.children) {
 if(screen.type!=='FRAME')continue;
 screen.fills=paint(C.bg);
 screen.strokes=paint(C.outline);
}
const existing = page.children.filter(n=>n.type==='FRAME');
const home=existing[0], guest=existing[1], desktop=existing[2], codex=existing[3], recovery=existing[4];
guest.x=858;desktop.x=1287;codex.x=1716;recovery.x=2145;
home.name='01 / SwiftDesk simplicity / launchpad';
updateText(home,'Main heading','One tap, anywhere.',23);
updateText(home,'Main subheading','Your PC and Android instances are ready.',12);
updateText(home,'Monitor title','Monitor 1');
updateText(home,'Android heading','Android instances');
updateText(home,'Host name','jarvis');
updateText(home,'Monitor glyph','M·',15);
guest.name='03 / OSLink immersion / BlueStacks';
updateText(guest,'Session title','MapleStory Idle',18);
updateText(guest,'Game label','BlueStacks 1');
updateText(guest,'Illustrative stream label','LIVE GAME FEED');
desktop.name='04 / Jump readability / Windows';
updateText(desktop,'Remote connection','Direct LAN · 3 ms');
codex.name='05 / Codex / conversation first';
recovery.name='06 / Recovery / actionable status';

// Add a dedicated target-switcher artboard. Mirrors OSLink's rapid multi-guest
// access and Splashtop's monitor switching while retaining MIRPG branding.
const s=box(page,'02 / OSLink + Splashtop / live view switcher',429,0,393,852,C.bg,24,C.outline);
label(s,'Device clock','12:49',20,11,85,23,13,C.ink,true);
label(s,'System status','●  Wi-Fi 86%',274,11,102,23,11,C.muted,false,'RIGHT');
label(s,'Eyebrow','CONNECTED TO JARVIS',20,61,305,21,11,C.mint,true);
label(s,'Main heading','Switch view',20,94,302,46,29,C.ink,true);
label(s,'Subtitle','Jump between live screens in one tap.',20,141,346,29,12,C.muted);
const counter=box(s,'Connection state',20,185,353,53,C.deep,13,C.outline);
circle(counter,'Green status light',13,21,10,C.mint);
label(counter,'Availability','5 views available',35,11,181,30,13,C.mint,true);
label(counter,'Network route','Direct LAN',243,13,96,27,11,C.muted,true,'RIGHT');
label(s,'Windows group','WINDOWS',20,259,173,23,11,C.muted,true);
label(s,'Monitor count','2 DISPLAYS',252,259,120,23,10,C.muted,true,'RIGHT');

function thumbnail(host,name,previewType){
 const g=box(host,name,10,10,92,58,previewType==='game'?'#356A5F':previewType==='stopped'?'#23343B':C.blue,8);
 if(previewType==='monitor'){
   shape(g,'Windows panel',9,16,56,34,C.light,3);
   shape(g,'Explorer top',9,16,56,9,'#B7D1DA',3);
   for(let i=0;i<3;i++)shape(g,'Explorer line '+i,15,30+i*6,34-i*6,3,i===0?C.mint:'#A8BCC6',2);
   shape(g,'Code panel',62,22,25,29,C.surface,3);
   shape(g,'Code line',66,30,16,3,C.mint,2);
 } else if(previewType==='game'){
   shape(g,'Distant hills',0,26,92,32,C.forest,0);
   circle(g,'Character head',36,23,22,'#F0CDA0');
   shape(g,'Character body',37,44,20,14,'#6385A7',4);
   circle(g,'Game light',10,12,13,'#A7DBC5');
 } else if(previewType==='stopped'){
   label(g,'Start symbol','▶',30,12,37,34,21,C.mint,true,'CENTER');
 }
 return g;
}
function target(name,y,title,subtitle,action,previewType,selected=false){
 const row=box(s,name,20,y,353,83,selected?C.deep:C.surface,13,selected?C.mint:C.outline);
 thumbnail(row,'Mini live preview',previewType);
 label(row,'Device',title,116,13,197,26,14,C.ink,true);
 label(row,'State',subtitle,116,38,212,18,11,C.muted);
 label(row,'Action',action,116,59,208,21,11,previewType==='stopped'?C.warm:C.mint,true);
 label(row,'Open indicator',selected?'✓':'›',315,23,31,40,24,selected?C.mint:C.muted,true,'CENTER');
}
target('Active Monitor 1',294,'Monitor 1','Windows · Live','Currently viewing','monitor',true);
target('Monitor 2',386,'Monitor 2','Windows · Live','Tap to open','monitor');
label(s,'Android group','ANDROID',20,486,173,23,11,C.muted,true);
label(s,'Instance count','3 INSTANCES',246,486,126,23,10,C.muted,true,'RIGHT');
target('BlueStacks Idle',519,'MapleStory Idle','BlueStacks 1 · Live','Tap to control','game');
target('BlueStacks R',611,'MapleStory R','BlueStacks 2 · Live','Tap to control','game');
target('BlueStacks Stopped',703,'BlueStacks 3','Stopped · Android 11','▶ Boot instance','stopped');
shape(s,'Android gesture bar',141,840,111,4,C.outline,2);

console.log('Updated '+page.children.filter(n=>n.type==='FRAME').length+' editable artboards');
