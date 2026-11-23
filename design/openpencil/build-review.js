// Editable OpenPencil/Figma scene: run through `openpencil eval <fig> --stdin -w`.
// Illustrative proposals based on current Flutter source and supplied screenshots.
const p = figma.currentPage;
for (const child of [...p.children]) child.remove();
p.name = 'MIRPG Remote / UI review / 2026-10-12';

const C = {
  bg:'#101416', surface:'#191F22', raised:'#242C30', divider:'#303A3E',
  outline:'#3E494E', ink:'#F1F4F5', muted:'#AEBAC0', mint:'#70D8C1',
  mintDark:'#16382F', teal:'#21433F', pale:'#C7FAED', error:'#FFB4AB',
  errorDark:'#3B2829', warning:'#EAC98B', warningDark:'#342D23',
  black:'#0B0E10', blue:'#1D3848', green:'#284E43', mauve:'#414359',
};

function rgb(h) { h=h.replace('#',''); return {r:parseInt(h.slice(0,2),16)/255,g:parseInt(h.slice(2,4),16)/255,b:parseInt(h.slice(4,6),16)/255}; }
function fill(h) { return [{type:'SOLID',color:rgb(h)}]; }
function frame(parent,name,x,y,w,h,color,rad=0,stroke=null) {
  const n=figma.createFrame(); n.name=name; parent.appendChild(n); n.resize(w,h); n.x=x; n.y=y;
  n.fills= color ? fill(color) : []; n.cornerRadius=rad; n.clipsContent=true;
  if (stroke){n.strokes=fill(stroke);n.strokeWeight=1;} return n;
}
function rect(parent,name,x,y,w,h,color,rad=0,stroke=null) {
  const n=figma.createRectangle(); n.name=name; parent.appendChild(n); n.resize(w,h); n.x=x; n.y=y;
  n.fills=color?fill(color):[]; n.cornerRadius=rad;
  if(stroke){n.strokes=fill(stroke);n.strokeWeight=1;} return n;
}
function circle(parent,name,x,y,d,color,stroke=null) {
  const n=figma.createEllipse(); n.name=name; parent.appendChild(n); n.resize(d,d); n.x=x;n.y=y;
  n.fills=color?fill(color):[]; if(stroke){n.strokes=fill(stroke);n.strokeWeight=1;} return n;
}
const fonts={regular:{family:'Inter',style:'Regular'},bold:{family:'Inter',style:'Bold'}};
for (const font of Object.values(fonts)) await figma.loadFontAsync(font);
function txt(parent,name,str,x,y,w,h,size=14,color=C.ink,bold=false,align='LEFT') {
  const t=figma.createText(); t.name=name; parent.appendChild(t);
  t.fontName=bold?fonts.bold:fonts.regular; t.characters=String(str);
  t.fontSize=size; t.fills=fill(color);t.textAutoResize='NONE';t.resize(w,h);
  t.x=x;t.y=y;t.textAlignHorizontal=align;t.textAlignVertical='CENTER';
  return t;
}
function pill(parent,name,label,x,y,w,h,background,color=C.ink,stroke=null,size=12){
  const g=frame(parent,name,x,y,w,h,background,Math.min(16,h/2),stroke);
  txt(g,'Label',label,7,0,w-14,h,size,color,true,'CENTER');return g;
}
function button(parent,name,label,x,y,w,h,primary=true){
  const g=frame(parent,name,x,y,w,h,primary?C.mint:C.raised,12,primary?null:C.outline);
  txt(g,'Button label',label,8,0,w-16,h,14,primary?C.bg:C.ink,true,'CENTER');return g;
}
function status(parent){
  txt(parent,'Mock device clock','12:49',20,10,80,26,13,C.ink,true);
  txt(parent,'Status indicators','●  Wi-Fi  86%',273,10,102,26,11,C.muted,false,'RIGHT');
}
function hostBar(parent){
  rect(parent,'Host icon',20,59,43,43,C.raised,11,C.outline);
  txt(parent,'Monitor glyph','PC',25,65,33,30,14,C.mint,true,'CENTER');
  txt(parent,'Host name','jarvis',75,54,156,33,23,C.ink,true);
  txt(parent,'Connection label','Connected workspace',75,86,182,18,11,C.muted);
  pill(parent,'Direct connection','Direct · 2 ms',261,65,112,32,C.mintDark,C.mint,C.teal,12);
  rect(parent,'Header divider',0,119,393,1,C.divider);
}
function nav(parent,active){
  rect(parent,'Navigation backdrop',0,758,393,94,C.surface);
  rect(parent,'Navigation divider',0,758,393,1,C.divider);
  const items=[['Overview','PC'],['System','SYS'],['Files','F'],['Shell','>_'],['Codex','<>']];
  items.forEach(([title,icon],i)=>{
    const x=7+i*79;
    if(active===title) rect(parent,title+' active indicator',x+6,767,61,35,C.mintDark,13);
    txt(parent,title+' icon',icon,x+10,768,53,31,icon.length>2?14:18,active===title?C.mint:C.muted,true,'CENTER');
    txt(parent,title+' nav',title,x,807,78,27,12,active===title?C.ink:C.muted,active===title,'CENTER');
  });
  rect(parent,'System home indicator',136,843,121,4,C.outline,2);
}
function phone(name,x){return frame(p,name,x,0,393,852,C.bg,24,C.outline);}
function miniDesktop(parent,x,y,w,h){
  const g=frame(parent,'Illustrative desktop thumbnail',x,y,w,h,C.blue,9);
  rect(g,'Desktop top band',0,0,w,17,'#172D39');
  circle(g,'Desktop light',9,6,5,C.mint);
  txt(g,'Desktop label','Jarvis · Windows',22,1,w-35,15,9,C.muted);
  rect(g,'Explorer window',13,30,w*0.58,h-49,'#E5E8E9',5);
  rect(g,'Explorer header',13,30,w*0.58,18,'#A8C3CE',5);
  rect(g,'Explorer sidebar',13,49,40,h-68,'#C2CFD2');
  for(let i=0;i<4;i++)rect(g,'File row '+i,62,58+i*12,w*0.39,5,i===0?'#88C8B7':'#BEC9CB',2);
  rect(g,'Code window',w*0.58+12,38,w*0.37,h-66,'#1D232B',5);
  for(let i=0;i<4;i++)rect(g,'Code line '+i,w*0.58+21,50+i*11,Math.max(15,w*0.3-i*11),4,i%2===0?C.mint:'#C3A7CE',2);
  rect(g,'Windows taskbar',0,h-13,w,13,'#141D25');
  return g;
}
function miniGame(parent,x,y,w,h,stopped=false){
  const g=frame(parent,stopped?'Illustrative stopped guest':'Illustrative game thumbnail',x,y,w,h,stopped?'#20292B':'#294D44',9);
  if(!stopped){
    rect(g,'Sky',0,0,w,h*0.42,'#3C7774');
    rect(g,'Hills',0,h*0.42,w,h*0.26,'#3B6550');
    rect(g,'Ground',0,h*0.68,w,h*0.32,'#2E4433');
    for(let i=0;i<4;i++)circle(g,'Forest glow '+i,16+i*(w-32)/4,30+i%2*16,19,'#6F9680');
    rect(g,'Guest status strip',12,10,w-24,13,'#172F2F',6);
    rect(g,'Guest action panel',15,h-28,w-30,17,'#27443A',8);
    for(let i=0;i<3;i++)circle(g,'Game action '+i,26+i*25,h-25,11,i===0?C.warning:C.mintDark);
  } else {
    circle(g,'Power symbol background',w/2-20,h/2-26,40,C.raised,C.outline);
    txt(g,'Start glyph','▶',w/2-15,h/2-22,30,32,19,C.mint,true,'CENTER');
  }
  return g;
}

// 01 — connected dashboard: live previews, obvious statuses, direct launch.
{
  const s=phone('01 / Overview / compact live targets',0); status(s); hostBar(s);
  txt(s,'Main heading','Your workspace',20,141,280,36,24,C.ink,true);
  txt(s,'Main subheading','Jump into a live screen in one tap',20,177,340,22,13,C.muted);
  pill(s,'All views selected','All views',20,213,95,31,C.mintDark,C.mint,C.teal);
  pill(s,'Windows filter','2 monitors',125,213,111,31,C.raised,C.muted,C.divider);
  pill(s,'Android filter','3 Android',245,213,128,31,C.raised,C.muted,C.divider);
  const m=frame(s,'Live Monitor 1 card',20,263,353,222,C.surface,16,C.outline);
  txt(m,'Monitor title','Monitor 1',16,12,178,27,17,C.ink,true);
  pill(m,'Monitor status','● LIVE',255,13,82,24,C.mintDark,C.mint,null,11);
  miniDesktop(m,16,49,321,119);
  txt(m,'Desktop connection','Windows · Direct LAN',16,181,230,26,12,C.muted);
  txt(m,'Open affordance','Open  →',256,179,81,30,13,C.mint,true,'RIGHT');
  txt(s,'Android heading','Android instances',20,497,275,29,18,C.ink,true);
  txt(s,'Android caption','Start, watch or switch instantly',20,526,290,18,12,C.muted);
  const a=frame(s,'BlueStacks 1 live card',20,552,170,186,C.surface,15,C.outline);
  miniGame(a,11,11,148,100);
  txt(a,'BlueStacks 1 name','BlueStacks 1',11,122,150,22,14,C.ink,true);
  txt(a,'BlueStacks 1 state','● Live · MapleStory',11,148,151,22,11,C.mint);
  const b=frame(s,'BlueStacks 3 stopped card',203,552,170,186,C.surface,15,C.outline);
  miniGame(b,11,11,148,100,true);
  txt(b,'BlueStacks 3 name','BlueStacks 3',11,122,150,22,14,C.ink,true);
  txt(b,'BlueStacks 3 boot action','▶  Boot instance',11,148,148,24,12,C.mint,true);
  nav(s,'Overview');
}

// 02 — Android guest: content first with Android controls on right and a view switcher on left.
{
  const s=phone('02 / BlueStacks / immersive portrait session',429);status(s);
  txt(s,'Back affordance','←',18,53,36,46,25,C.ink,true);
  txt(s,'Session title','BlueStacks 3',60,54,230,28,19,C.ink,true);
  txt(s,'Game label','MapleStory Idle RPG',60,82,225,20,12,C.muted);
  pill(s,'Guest live state','● Live',299,58,76,27,C.mintDark,C.mint,null,11);
  const g=frame(s,'Remote Android display / conceptual live feed',18,119,309,584,'#1B3A35',17,C.outline);
  rect(g,'Game sky',0,0,309,190,'#3A716A');
  rect(g,'Game mountains',0,190,309,110,'#426754');
  rect(g,'Game forest',0,300,309,284,'#253E34');
  for(let i=0;i<6;i++)circle(g,'Scenery '+i,20+i*59,155+(i%3)*52,42,i%2?'#476E52':'#5E856C');
  rect(g,'Game title backdrop',17,23,190,42,'#203F3A',12);
  txt(g,'Illustrative stream label','LIVE GAME FEED',29,25,168,38,16,C.pale,true);
  rect(g,'Game UI progress background',18,76,212,12,'#274940',6);
  rect(g,'Game UI progress',18,76,158,12,C.mint,6);
  circle(g,'Conceptual player shadow',129,270,108,'#193D3A');
  circle(g,'Conceptual player avatar',144,281,76,'#F1C89D');
  rect(g,'Conceptual sprite shirt',135,350,96,88,'#6382A4',18);
  rect(g,'Guest action backdrop',17,497,275,65,'#1A352F',15);
  for(let i=0;i<4;i++){
    circle(g,'Guest action circle '+i,36+i*76,508,43,i===0?C.warning:C.teal);
  }
  // Left switcher floats over feed.
  const left=frame(s,'Left target switcher',9,340,53,126,C.surface,17,C.outline);
  txt(left,'View switcher glyph','SW',5,12,43,38,16,C.mint,true,'CENTER');
  txt(left,'View switcher label','Views',5,51,43,24,11,C.ink,true,'CENTER');
  txt(left,'Switcher count','5',8,84,37,27,15,C.muted,true,'CENTER');
  // Right Android navigation in video margin/overlay.
  const rail=frame(s,'Right Android control rail',328,270,54,248,C.surface,19,C.outline);
  txt(rail,'Back control','←',6,9,42,42,26,C.ink,true,'CENTER');
  txt(rail,'Back label','Back',3,48,48,20,11,C.muted,false,'CENTER');
  txt(rail,'Home control','H',5,83,44,40,21,C.ink,true,'CENTER');
  txt(rail,'Home label','Home',3,121,48,20,11,C.muted,false,'CENTER');
  txt(rail,'Recents control','□',5,153,44,40,27,C.ink,true,'CENTER');
  txt(rail,'Recents label','Recents',1,190,52,20,10,C.muted,false,'CENTER');
  rect(rail,'Rail handle',17,225,20,4,C.divider,2);
  pill(s,'Connection health','LAN · 60 fps',20,719,136,32,C.mintDark,C.mint,C.teal,11);
  pill(s,'Keyboard action','Keyboard',244,719,129,32,C.raised,C.ink,C.outline,12);
  txt(s,'Guest interaction hint','Tap to control · swipe left rail to switch targets',20,763,353,29,12,C.muted);
  rect(s,'Home gesture bar',136,839,121,4,C.outline,2);
}

// 03 — Windows monitor: readable zoom and trackpad controls.
{
  const s=phone('03 / Windows / readable pointer control',858);status(s);
  txt(s,'Back affordance','←',18,53,36,46,25,C.ink,true);
  txt(s,'Monitor header','Monitor 1',60,53,202,28,20,C.ink,true);
  txt(s,'Remote connection','Direct connection · 2 ms',60,81,240,21,12,C.muted);
  pill(s,'Quality state','● Live',299,58,76,27,C.mintDark,C.mint,null,11);
  pill(s,'Fit preset','Fit',20,124,102,39,C.raised,C.muted,C.outline,13);
  pill(s,'Readable selected','Readable',131,124,129,39,C.mintDark,C.mint,C.teal,13);
  pill(s,'Magnification preset','180%',268,124,105,39,C.raised,C.ink,C.outline,13);
  txt(s,'Remote gesture helper','Mouse mode  ·  pinch to zoom  ·  2 fingers scroll',20,171,353,25,12,C.muted);
  const m=frame(s,'Remote PC viewport / zoomed representative desktop',12,212,369,487,'#163543',14,C.outline);
  // Oversized virtual desktop section rather than unreadably scaled entire 2K display.
  rect(m,'Desktop wallpaper',0,0,369,487,'#19394A');
  rect(m,'Taskbar top',0,0,369,31,'#122834');
  txt(m,'Windows desktop title','Windows 11 · Jarvis',13,5,232,22,12,C.ink,true);
  const w=frame(m,'File explorer window',17,52,324,294,'#E5ECEC',8);
  rect(w,'Explorer title bar',0,0,324,37,'#BDD3D9',8);
  txt(w,'Explorer title','File Explorer',14,5,240,27,14,'#203842',true);
  rect(w,'Explorer sidebar',0,37,90,257,'#D0DFE1');
  const folders=['Desktop','Downloads','Projects','Pictures'];
  folders.forEach((name,i)=>txt(w,'Explorer folder '+i,name,11,55+i*41,74,25,12,'#3B575F',i===2));
  txt(w,'Explorer path','This PC > Documents',104,46,199,29,12,'#40585E');
  for(let i=0;i<3;i++){
    rect(w,'Folder icon '+i,117+i*62,111,40,32,i===1?'#B0CFC0':'#BFCAD8',5);
    txt(w,'Folder name '+i,['Work','Code','Tools'][i],105+i*62,150,62,26,11,'#1A3941',false,'CENTER');
  }
  rect(w,'Content divider',101,186,203,1,'#B9C7C7');
  txt(w,'Readable content','Files and buttons stay tappable',110,202,194,64,13,'#2E4549');
  // Minimap communicates current crop within 2K canvas.
  const mm=frame(m,'Full desktop minimap',224,360,128,77,'#1D2630',8,C.outline);
  rect(mm,'Mini file window',10,10,108,55,'#7994A3',3);
  rect(mm,'Current visible region',35,20,66,41,'#263C47',3,C.mint);
  txt(m,'Live resolution indicator','2560 × 1440 source',14,452,185,24,11,C.muted);
  const float=frame(s,'Floating view switcher',15,522,55,102,C.surface,18,C.outline);
  txt(float,'Switcher icon','SW',7,8,40,39,16,C.mint,true,'CENTER');
  txt(float,'Switcher text','Switch',4,48,48,26,11,C.ink,true,'CENTER');
  const ctrls=frame(s,'Session controls',12,713,369,111,C.surface,16,C.outline);
  [['Mouse','M'],['Keyboard','KB'],['Right click','R'],['Targets','SW']].forEach(([label,icon],i)=>{
    const x=11+i*90;
    if(i===0)rect(ctrls,'Selected mouse mode',x,10,82,81,C.mintDark,12);
    txt(ctrls,label+' control',icon,x+3,14,76,39,23,i===0?C.mint:C.ink,true,'CENTER');
    txt(ctrls,label+' caption',label,x+1,61,80,25,11,C.muted,false,'CENTER');
  });
  rect(s,'Home gesture bar',136,839,121,4,C.outline,2);
}

// 04 — Codex: task status + grouped technical work, readable conversation.
{
  const s=phone('04 / Codex / chat-first task activity',1287);status(s);hostBar(s);
  txt(s,'Thread back','←',17,133,34,45,24,C.ink,true);
  txt(s,'Thread heading','Codex Web GPT Revamp',61,134,306,31,18,C.ink,true);
  txt(s,'Thread status','● Running now  ·  2 actions in progress',62,164,295,24,12,C.mint);
  rect(s,'Thread line',0,199,393,1,C.divider);
  pill(s,'Conversation tab selected','Conversation',18,212,206,41,C.mintDark,C.mint,C.teal,13);
  pill(s,'Review tab','Review',231,212,144,41,C.surface,C.muted,C.divider,13);
  txt(s,'Timeline date','TODAY · OCT 12',20,277,200,25,11,C.muted,true);
  const user=frame(s,'User message',71,317,301,90,C.raised,15);
  txt(user,'User query','Review the current UI and fix',14,13,272,27,14,C.ink);
  txt(user,'Second query line','the navigation and controls.',14,42,272,27,14,C.ink);
  const assistant=frame(s,'Assistant response',19,429,354,130,C.surface,15,C.outline);
  circle(assistant,'Assistant marker',14,15,29,C.mintDark);
  txt(assistant,'Assistant name','Codex',54,13,260,30,14,C.pale,true);
  txt(assistant,'Assistant response line 1','I found a preview-state mismatch',17,54,320,23,14,C.ink);
  txt(assistant,'Assistant response line 2','and an overflowing command log.',17,78,320,23,14,C.ink);
  txt(assistant,'Assistant response line 3','Preparing the review and screenshots.',17,102,325,20,12,C.muted);
  const tools=frame(s,'Collapsed activity group',19,575,354,74,C.raised,13,C.outline);
  txt(tools,'Tool icon','>_',15,10,43,45,16,C.mint,true);
  txt(tools,'Tool group label','Tool activity  ·  4 calls',58,9,259,26,14,C.ink,true);
  txt(tools,'Tool group subtitle','3 completed  ·  1 running',58,37,269,24,12,C.muted);
  txt(tools,'Activity expandable chevron','⌄',318,15,24,40,23,C.muted,true);
  const composer=frame(s,'Task input area',19,660,354,63,C.surface,14,C.outline);
  txt(composer,'Composer placeholder','Ask Codex or add instructions...',14,10,305,43,13,C.muted);
  pill(s,'View Windows action','Open live task  >',204,728,169,28,C.mintDark,C.mint,C.teal,11);
  nav(s,'Codex');
}

// 05 — meaningful reconnect/stream failure state instead of empty black or opaque errors.
{
  const s=phone('05 / Connection / recoverable stream error',1716);status(s);hostBar(s);
  txt(s,'Error page title','Your workspace',20,144,319,35,24,C.ink,true);
  const con=frame(s,'Overall connection status',20,198,353,60,C.mintDark,13,C.teal);
  circle(con,'Network health dot',16,21,16,C.mint);
  txt(con,'PC connected state','PC connected · LAN 2 ms',42,9,285,30,14,C.pale,true);
  txt(con,'Connection explanatory state','Jarvis is online and responding',42,35,290,19,12,C.muted);
  const error=frame(s,'Monitor stream error card',20,278,353,336,C.surface,16,C.outline);
  rect(error,'Error artwork background',17,16,319,117,'#1E292B',10);
  circle(error,'Stream warning icon',143,44,47,C.warningDark,C.warning);
  txt(error,'Stream warning glyph','!',148,49,37,36,27,C.warning,true,'CENTER');
  txt(error,'Stream issue title','Monitor 1 preview paused',20,149,310,33,18,C.ink,true);
  txt(error,'Stream issue text first','The PC is connected, but this video',20,190,318,25,13,C.muted);
  txt(error,'Stream issue text second','stream has not produced a usable frame.',20,214,316,24,13,C.muted);
  button(error,'Reconnect stream','Retry preview',20,254,153,52,true);
  button(error,'Switch view','Switch view',183,254,150,52,false);
  txt(s,'Other targets heading','Other available views',20,638,320,30,17,C.ink,true);
  const other1=frame(s,'Alternate guest option',20,680,171,61,C.raised,12,C.divider);
  txt(other1,'Other guest icon','A',10,12,29,35,19,C.mint,true);
  txt(other1,'Other guest title','BlueStacks 1',42,9,122,22,12,C.ink,true);
  txt(other1,'Other guest state','● Live',42,31,114,21,11,C.mint);
  const other2=frame(s,'Alternate desktop option',202,680,171,61,C.raised,12,C.divider);
  txt(other2,'Other desktop icon','PC',10,12,29,35,14,C.mint,true);
  txt(other2,'Other desktop title','Monitor 2',42,9,118,22,12,C.ink,true);
  txt(other2,'Other desktop state','Try opening',42,31,114,21,11,C.muted);
  nav(s,'Overview');
}

console.log('Built '+p.children.length+' editable screens.');
