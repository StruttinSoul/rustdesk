// MIRPG Remote · STUDIO V4. Editable OpenPencil-native vector composition.
// Source HTML is the browser visual reference; this FIG approximates that design.
const p=figma.currentPage;
p.name='MIRPG STUDIO V4 / Professional light interface / 2026-10-12';
for(const n of [...p.children])n.remove();
const C={bg:'#F5F7FA',white:'#FFFFFF',ink:'#192431',muted:'#5E6D7F',quiet:'#526273',
line:'#DCE3EA',soft:'#EDF1F5',blue:'#2855CC',bluePale:'#EAF0FF',good:'#0C795D',
goodPale:'#E4F5EF',stage:'#172533',stage2:'#283F56',navy:'#223247',blueSky:'#93B8D1',
paper:'#E7F0F4',pane:'#C6DAE5',purple:'#7989BB',purpleSky:'#A6AED5',tan:'#F0CBA2',
teal:'#5685A3',teal2:'#457E8F',red:'#BA6960',gold:'#DCAC70'};
function rgb(h){h=h.replace('#','');return{r:parseInt(h.slice(0,2),16)/255,g:parseInt(h.slice(2,4),16)/255,b:parseInt(h.slice(4,6),16)/255};}
function fill(h){return[{type:'SOLID',color:rgb(h)}];}
const fontR={family:'Inter',style:'Regular'},fontB={family:'Inter',style:'Bold'};
await figma.loadFontAsync(fontR);await figma.loadFontAsync(fontB);
function box(parent,name,x,y,w,h,bg,rad=0,stroke=null){
 const n=figma.createFrame();parent.appendChild(n);n.name=name;n.resize(w,h);n.x=x;n.y=y;
 n.fills=bg?fill(bg):[];n.cornerRadius=rad;n.clipsContent=true;
 if(stroke){n.strokes=fill(stroke);n.strokeWeight=1;}return n;
}
function rect(parent,name,x,y,w,h,bg,rad=0,stroke=null){
 const n=figma.createRectangle();parent.appendChild(n);n.name=name;n.resize(w,h);n.x=x;n.y=y;
 n.fills=bg?fill(bg):[];n.cornerRadius=rad;
 if(stroke){n.strokes=fill(stroke);n.strokeWeight=1;}return n;
}
function dot(parent,name,x,y,d,bg,stroke=null){
 const n=figma.createEllipse();parent.appendChild(n);n.name=name;n.resize(d,d);n.x=x;n.y=y;
 n.fills=bg?fill(bg):[];if(stroke){n.strokes=fill(stroke);n.strokeWeight=1;}return n;
}
function text(parent,name,value,x,y,w,h,size=14,color=C.ink,strong=false,align='LEFT'){
 const n=figma.createText();parent.appendChild(n);n.name=name;n.fontName=strong?fontB:fontR;
 n.characters=String(value);n.fontSize=size;n.fills=fill(color);n.textAutoResize='NONE';n.resize(w,h);
 n.x=x;n.y=y;n.textAlignHorizontal=align;n.textAlignVertical='CENTER';return n;
}
function line(parent,name,x,y,w,color=C.line){return rect(parent,name,x,y,w,1,color);}
function segment(parent,name,x1,y1,x2,y2,color=C.ink,weight=2){
 const n=figma.createLine();parent.appendChild(n);n.name=name;
 n.resize(Math.hypot(x2-x1,y2-y1),0);n.x=x1;n.y=y1;
 n.rotation=Math.atan2(y2-y1,x2-x1)*180/Math.PI;
 n.strokes=fill(color);n.strokeWeight=weight;return n;
}
function outline(parent,name,x,y,w,h,color,rad=2,weight=2){
 const n=rect(parent,name,x,y,w,h,null,rad,color);n.strokeWeight=weight;return n;
}
function icon(parent,name,x,y,color){
 // Compact, editable line icon drawn in a dedicated 26x26 frame.
 const f=box(parent,'Vector icon / '+name,x,y,26,26,null);
 if(name==='Home'){
   segment(f,'Roof left',3,13,13,4,color);
   segment(f,'Roof right',13,4,23,13,color);
   segment(f,'Left wall',5,12,5,23,color);
   segment(f,'Right wall',21,12,21,23,color);
   segment(f,'House floor',5,23,21,23,color);
   outline(f,'Door',11,16,5,7,color,1,1.6);
 }else if(name==='Screens'){
   outline(f,'Rear monitor',8,3,16,15,color,2);
   outline(f,'Front monitor',2,8,17,15,color,2);
   rect(f,'Monitor stand',8,23,8,2,color,1);
 }else if(name==='Tools'){
   [6,13,20].forEach((y,i)=>{
     rect(f,'Slider track '+i,3,y,20,2,color,1);
     dot(f,'Slider knob '+i,i===1?7:17,y-3,8,color);
   });
 }else if(name==='Codex'){
   outline(f,'Terminal boundary',2,3,22,20,color,3,1.8);
   segment(f,'Prompt upper',7,9,12,13,color);
   segment(f,'Prompt lower',12,13,7,17,color);
   rect(f,'Cursor',14,17,6,2,color,1);
 }else if(name==='Recents'){
   outline(f,'Back card',8,3,15,18,color,2,1.7);
   outline(f,'Front card',3,7,15,18,color,2,1.7);
 }else if(name==='Keyboard'){
   outline(f,'Keyboard outline',1,5,24,17,color,3,1.8);
   [5,11,17].forEach((yy,i)=>{
     for(let j=0;j<4;j++)rect(f,'Key '+i+'-'+j,4+j*5,yy+(i===0?4:i===1?0:-4),3,2,color,0.5);
   });
   rect(f,'Spacebar',8,18,10,1.8,color,1);
 }else if(name==='Pointer'){
   const pts=[[3,2],[5,24],[11,18],[16,24],[20,22],[15,16],[24,13],[3,2]];
   for(let i=1;i<pts.length;i++)segment(f,'Cursor edge '+i,...pts[i-1],...pts[i],color,1.8);
 }else if(name==='Right click'){
   outline(f,'Mouse',6,2,14,23,color,7,1.8);
   segment(f,'Middle',13,3,13,13,color,1.7);
   segment(f,'Click line',7,13,19,13,color,1.7);
   rect(f,'Right button',14,5,4,6,color,1);
 }
 return f;
}
function card(parent,name,x,y,w,h){return box(parent,name,x,y,w,h,C.white,15,C.line);}
function pill(parent,name,label,x,y,w,kind='green'){
 const bg=kind==='blue'?C.bluePale:kind==='green'?C.goodPale:C.soft;
 const fg=kind==='blue'?C.blue:kind==='green'?C.good:C.muted;
 const b=box(parent,name,x,y,w,26,bg,9);text(b,'Label',label,7,1,w-14,24,11,fg,true,'CENTER');return b;
}
function btn(parent,name,label,x,y,w,h=46,primary=false){
 const b=box(parent,name,x,y,w,h,primary?C.blue:C.white,11,primary?null:C.line);
 text(b,'Button label',label,7,0,w-14,h,12,primary?C.white:C.ink,true,'CENTER');return b;
}
function status(s,dark=false){
 text(s,'Device time','12:49',20,2,85,31,13,dark?C.white:C.ink,true);
 dot(s,'Network dot',288,15,6,dark?C.blueSky:C.good);
 text(s,'Phone Wi-Fi','Wi-Fi 86%',299,4,74,27,11,dark?'#C6D5E9':C.muted,false,'RIGHT');
}
function brand(s){
 const m=box(s,'MIRPG monogram',20,45,40,40,C.blue,12);
 text(m,'Brand M','M',3,1,34,35,22,C.white,true,'CENTER');
 rect(m,'Brand cyan dot',29,28,5,5,C.blueSky,2);
 text(s,'Brand title','mirpg',72,43,159,28,21,C.ink,true);
 text(s,'Brand subtitle','Remote workspace',72,72,207,21,11,C.muted);
 const more=box(s,'Settings action',330,46,43,43,C.white,12,C.line);
 text(more,'Ellipsis','...',5,6,33,30,20,C.muted,true,'CENTER');
}
function nav(s,which){
 const b=box(s,'Persistent bottom navigation',0,772,393,80,C.white);
 line(b,'Navigation divider',0,0,393,C.line);
 ['Home','Screens','Tools','Codex'].forEach((name,i)=>{
   const x=16+i*95;const active=name===which;
   if(active)rect(b,'Active '+name+' rail',x+22,0,51,3,C.blue,2);
   icon(b,name,x+31,12,active?C.blue:C.quiet);
   text(b,name+' caption',name,x+1,42,86,21,11,active?C.blue:C.muted,active,'CENTER');
 });
 rect(b,'Bottom gesture',140,74,113,4,C.quiet,2);
}
function gesture(s,dark=false){rect(s,'Android gesture indicator',141,842,111,4,dark?C.muted:C.quiet,2);}
function section(s,name,y,action=''){
 text(s,name+' heading',name,20,y,252,29,17,C.ink,true);
 if(action)text(s,name+' action',action,275,y,98,29,11,C.blue,true,'RIGHT');
}
function desktop(parent,x,y,w,h){
 const d=box(parent,'Illustrative Windows preview',x,y,w,h,'#8CADC8',8);
 rect(d,'Sky wallpaper',0,0,w,h*.65,'#9FC2D9');
 rect(d,'Wallpaper pane',w*.55,0,w*.45,h*.95,'#78A2BD');
 const explorer=box(d,'Simulated File Explorer',w*.08,h*.14,w*.58,h*.73,'#F5FAFC',4);
 rect(explorer,'Explorer bar',0,0,explorer.width,Math.max(10,h*.15),C.pane,3);
 rect(explorer,'Folder sidebar',0,h*.15,w*.12,explorer.height-h*.15,C.paper);
 for(let i=0;i<3;i++)rect(explorer,'File row '+i,w*.17,h*.3+i*h*.12,w*(.31-i*.05),Math.max(3,h*.03),i?C.pane:'#7AB2C9',2);
 const editor=box(d,'Simulated code editor',w*.57,h*.34,w*.35,h*.46,C.stage,4);
 for(let i=0;i<4;i++)rect(editor,'Code stripe '+i,9,9+i*h*.085,Math.max(10,w*(.20-i*.025)),Math.max(3,h*.028),i%2?'#A6A6D6':'#7CC8E1',2);
 rect(d,'Windows taskbar',0,h-11,w,11,C.stage2);
 dot(d,'Windows Start button',9,h-8,5,C.white);
 return d;
}
function game(parent,x,y,w,h,alt=false){
 const g=box(parent,alt?'MapleStory R illustrative preview':'MapleStory Idle illustrative preview',x,y,w,h,alt?C.purple:C.teal,8);
 rect(g,'Game sky',0,0,w,h*.49,alt?C.purpleSky:C.blueSky);
 dot(g,'Sun',w*.65,h*.17,Math.min(w*.18,26),alt?'#EDCFC8':'#F6E0BB');
 rect(g,'Foreground',0,h*.57,w,h*.43,alt?'#5C6691':'#46768B');
 for(let i=0;i<3;i++)dot(g,'Hills '+i,i*w*.41-22,h*.47,Math.min(w*.51,73),alt?'#777FA9':'#6791A6');
 dot(g,'Game hero head',w*.47,h*.50,Math.min(28,w*.23),C.tan);
 rect(g,'Game hero body',w*.42,h*.70,Math.min(36,w*.31),h*.24,alt?'#A9B2DD':'#6795B5',6);
 rect(g,'Game HUD line',9,10,w*.35,4,'#EAF5FC',2);
 return g;
}
function board(name,i,bg=C.bg){return box(p,name,i*429,0,393,852,bg,24,C.line);}

// 01 HOME
{
 const s=board('01 / Home / Light workspace',0);status(s);brand(s);
 text(s,'Connected kicker','CONNECTED TO',20,116,233,19,10,C.quiet,true);
 text(s,'PC host name','Jarvis',20,137,210,49,34,C.ink,true);
 pill(s,'Host direct badge','Direct · 3 ms',255,151,118,'blue');
 text(s,'Home subtitle','Your PC and games, all in one place.',20,185,350,25,12,C.muted);
 section(s,'Continue working',220,'ALL SCREENS  →');
 const featured=card(s,'Featured Windows monitor',20,262,353,210);
 desktop(featured,10,10,333,148);
 text(featured,'Monitor title','Monitor 1',12,162,192,28,16,C.ink,true);
 pill(featured,'Monitor live','● Live',271,168,69,'green');
 text(featured,'Monitor subtitle','Windows · Recently viewed',12,188,233,19,11,C.muted);
 section(s,'Android instances',490,'VIEW ALL  →');
 const a=card(s,'BlueStacks 1 preview',20,531,170,207),b=card(s,'BlueStacks 2 preview',202,531,171,207);
 [[a,false,'MapleStory Idle','BlueStacks 1'],[b,true,'MapleStory R','BlueStacks 2']].forEach(([c,alt,title,desc])=>{
   game(c,9,9,alt?153:152,116,alt);
   text(c,'Game title',title,10,134,150,22,13,C.ink,true);
   text(c,'Game instance',desc,10,157,150,19,11,C.muted);
   text(c,'Game shortcut','● Live · Open',10,181,150,22,11,C.good,true);
 });
 text(s,'Stopped instance footer','BlueStacks 3 stopped · Open Screens to boot',20,744,353,20,11,C.muted);
 nav(s,'Home');
}
// 02 SCREENS
{
 const s=board('02 / Screens / Live view chooser',1);status(s);
 text(s,'Back button','←',20,50,46,38,25,C.ink,true);
 text(s,'Switcher title','All screens',20,91,268,42,29,C.ink,true);
 text(s,'Switcher subtitle','Jarvis · 5 available targets',20,129,252,29,13,C.muted);
 pill(s,'Transport mode','LAN',309,110,62,'green');
 const filters=card(s,'Target filters',20,176,353,45);
 rect(filters,'Active filter background',5,5,107,35,C.bluePale,10);
 [['All (5)',8,99],['Windows',118,104],['Android',235,104]].forEach(([val,x,w],i)=>
   text(filters,'Filter '+val,val,x,6,w,32,12,i===0?C.blue:C.muted,i===0,'CENTER'));
 text(s,'Windows group','WINDOWS  ·  2',20,237,210,25,11,C.quiet,true);
 function target(y,title,desc,selected=false){
   const r=card(s,'Monitor '+title+' row',20,y,353,95);
   desktop(r,8,9,109,76);
   text(r,'Screen label',title,131,11,182,25,15,C.ink,true);
   text(r,'Screen meta',desc,131,39,187,21,11,C.muted);
   text(r,'Screen open',selected?'Viewing now':'Open  →',131,65,177,21,11,selected?C.good:C.blue,true);
   text(r,'Chevron','›',320,26,28,35,24,C.quiet,true,'CENTER');
 }
 target(270,'Monitor 1','Windows · Online',true);
 target(372,'Monitor 2','Windows · Online');
 text(s,'Android group','ANDROID  ·  3',20,475,220,25,11,C.quiet,true);
 function guest(y,title,desc,alt=false,stopped=false){
   const r=card(s,'Guest '+title+' row',20,y,353,76);
   if(stopped){const st=box(r,'Boot tile',8,8,90,60,C.soft,8);text(st,'Boot icon','▶',25,15,42,32,20,C.blue,true,'CENTER');}
   else game(r,8,8,90,60,alt);
   text(r,'Guest title',title,109,8,232,24,14,C.ink,true);
   text(r,'Guest detail',desc,109,30,228,20,11,C.muted);
   text(r,'Guest action',stopped?'Start guest  →':'Open  →',216,53,122,19,11,C.blue,true,'RIGHT');
 }
 guest(507,'MapleStory Idle','BlueStacks 1 · Live');
 guest(590,'MapleStory R','BlueStacks 2 · Live',true);
 guest(673,'BlueStacks 3','Stopped · Android 11',false,true);
 gesture(s);
}
// 03 ANDROID IMMERSIVE
{
 const s=board('03 / Android / Immersive session',2,C.stage);
 const g=box(s,'Remote game video 317x852',0,0,316,852,C.purple);
 rect(g,'Game sky',0,0,316,370,C.purpleSky);
 dot(g,'Game lighting',206,176,62,'#E9D9C6');
 for(let i=0;i<4;i++)dot(g,'Scenery '+i,i*103-47,329+(i%2)*55,166,i%2?'#6E78A4':'#7D84AF');
 rect(g,'Game terrain',0,491,316,361,'#414F79');
 dot(g,'Hero hair',108,463,106,'#35446B');
 dot(g,'Hero face',123,479,76,C.tan);
 rect(g,'Hero shirt',114,546,104,130,'#6B8CB5',17);
 const head=box(g,'Game top chrome',0,0,316,114,'#283759');
 text(head,'Game name','MapleStory Idle',17,37,270,31,18,C.white,true);
 text(head,'Game live label','BlueStacks 1 · Live',17,69,270,21,12,'#DDE9F9');
 rect(head,'Game progress track',17,100,161,4,'#526482',2);
 rect(head,'Game progress fill',17,100,103,4,'#B8D5F4',2);
 const hud=box(g,'Game button HUD',12,754,291,72,'#29395D',14);
 for(let i=0;i<4;i++){
   const b=box(hud,'Game action button '+i,15+i*69,14,43,43,i===0?C.tan:'#445984',22);
   text(b,'Skill number',String(i+1),0,8,43,26,13,i===0?C.stage:C.white,true,'CENTER');
 }
 const sw=box(s,'Guest view switch handle',0,373,50,104,C.navy,0);
 rect(sw,'Switcher active accent',0,0,4,104,C.blue);
 text(sw,'Target count','5',8,14,34,35,22,C.white,true,'CENTER');
 text(sw,'Switcher caption','VIEWS',3,52,44,20,10,'#D4E2F0',true,'CENTER');
 const rail=box(s,'Reserved system button rail',319,0,74,852,C.stage);
 rect(rail,'Rail divider',0,0,1,852,'#415366');
 text(rail,'Android caption','ANDROID',7,51,60,31,10,'#C5D3E3',true,'CENTER');
 [['Back','←',224],['Home','',304],['Recents','',384],['Keyboard','',500]].forEach(([name,symbol,y])=>{
   const b=box(rail,name+' touch area',8,y,58,67,C.navy,11);
   if(name==='Back')text(b,name+' symbol',symbol,3,7,52,30,21,C.white,true,'CENTER');
   else icon(b,name,16,8,C.white);
   text(b,name+' label',name,1,42,56,20,10,'#C0CFDF',true,'CENTER');
 });
 text(rail,'Link','LAN',7,720,60,20,11,'#B7E9DC',true,'CENTER');
 text(rail,'Frame status','60 fps',7,747,60,20,11,'#C0CFDF',false,'CENTER');
 rect(rail,'Rail gesture',23,843,28,3,C.quiet,2);
}
// 04 WINDOWS
{
 const s=board('04 / Windows / Readable remote desktop',3);status(s);
 text(s,'Back arrow','←',20,54,41,38,24,C.ink,true);
 text(s,'Monitor 1 heading','Monitor 1',63,53,225,33,20,C.ink,true);
 text(s,'Live PC route','Jarvis · Direct LAN',63,86,228,20,12,C.muted);
 pill(s,'Monitor live tag','● Live',303,61,70,'green');
 const preset=card(s,'Display preset bar',20,123,353,48);
 rect(preset,'Selected readable display',111,6,124,36,C.bluePale,10);
 [['Fit',5,104],['Readable',113,121],['180%',249,96]].forEach(([v,x,w],i)=>text(preset,'Preset '+v,v,x,7,w,33,12,i===1?C.blue:C.muted,i===1,'CENTER'));
 const remote=box(s,'Windows video stage',20,186,353,438,'#426781',13);
 rect(remote,'Windows top line',0,0,353,37,C.stage2);
 text(remote,'Windows device label','Windows 11 · Jarvis',12,4,231,26,12,'#EAF3F7',true);
 const explorer=box(remote,'Readable File Explorer',43,60,292,297,C.paper,7);
 rect(explorer,'File Explorer top',0,0,292,38,C.pane,5);
 text(explorer,'File Explorer title','File Explorer',13,5,265,25,14,C.stage2,true);
 rect(explorer,'Sidebar',0,38,84,259,'#D7E6EE');
 ['Home','Desktop','Downloads','Projects'].forEach((n,i)=>text(explorer,'Sidebar '+n,n,10,50+i*46,73,25,11,'#435C70',i===3));
 text(explorer,'Breadcrumb','This PC > Documents',99,44,183,27,11,'#435C70');
 ['Work','Code','Tools'].forEach((n,i)=>{
    rect(explorer,n+' folder',105+i*58,97,35,30,i===0?'#799BB3':'#A2BCC8',4);
    text(explorer,n+' label',n,98+i*58,133,48,20,10,C.stage2,true,'CENTER');
 });
 line(explorer,'Separator',98,177,181,'#BFCFD8');
 ['MIRPG Remote','Gateway','Marquee'].forEach((n,i)=>{
    text(explorer,'Explorer item '+i,n,108,187+i*30,173,22,11,'#435C70');
    if(i<2)line(explorer,'Explorer item divider '+i,103,215+i*30,178,'#C5D4DC');
 });
 text(remote,'Source monitor dimensions','2560 × 1440 source',12,399,212,23,11,C.white,true);
 const map=box(remote,'Monitor minimap',241,366,95,51,C.stage,7);
 rect(map,'Full computer desktop',10,8,76,35,'#53798D',3);
 rect(map,'Readable viewport position',31,14,41,24,null,2,'#DBEFFF');
 const sw=box(s,'Left switch views handle',8,386,49,98,C.navy,11);
 text(sw,'View count','5',8,14,32,30,20,C.white,true,'CENTER');
 text(sw,'View label','Views',5,50,38,22,11,'#D6E2F2',true,'CENTER');
 text(s,'Gesture hint','Pinch to zoom · Two fingers to scroll',20,638,353,24,12,C.muted);
 const tools=card(s,'Windows precision tool strip',20,676,353,89);
 ['Pointer','Keyboard','Right click','Screens'].forEach((n,i)=>{
    const x=5+i*87;
    if(i===0)rect(tools,'Selected pointer rail',x+11,0,59,3,C.blue,2);
    icon(tools,n,x+28,14,i===0?C.blue:C.ink);
    text(tools,n+' label',n,x+1,49,80,23,11,i===0?C.blue:C.muted,i===0,'CENTER');
 });
 gesture(s);
}
// 05 CODEX
{
 const s=board('05 / Codex / Clean conversation',4);status(s);
 text(s,'Back button','←',18,51,42,41,25,C.ink,true);
 text(s,'Codex app label','Codex',63,53,191,37,24,C.ink,true);
 pill(s,'Codex running label','● Running',271,58,102,'green');
 line(s,'Thread header divider',20,107,353);
 text(s,'Thread title','Marquee NextGen',20,118,348,36,23,C.ink,true);
 text(s,'Workspace last updated','Jarvis · Updated just now',20,159,342,23,12,C.muted);
 const tabs=card(s,'Codex tabs',20,197,353,45);
 rect(tabs,'Active conversation',5,5,183,35,C.bluePale,10);
 text(tabs,'Conversation label','Conversation',7,6,181,32,12,C.blue,true,'CENTER');
 text(tabs,'Activity label','Activity',201,6,143,32,12,C.muted,false,'CENTER');
 text(s,'Timeline day','TODAY · OCT 12',20,259,227,20,11,C.quiet,true);
 const bubble=box(s,'User question',67,294,306,86,C.bluePale,13);
 text(bubble,'Request line 1','Review the current UI.',13,10,284,28,14,C.ink);
 text(bubble,'Request line 2','Keep the controls intuitive.',13,39,284,28,14,C.ink);
 const mark=box(s,'Codex emblem',20,405,31,31,C.blue,9);
 text(mark,'M', 'M',3,1,26,27,18,C.white,true,'CENTER');
 text(s,'Codex message author','Codex',62,405,225,29,13,C.ink,true);
 text(s,'Codex response line 1','I found the layout collisions and',20,447,353,26,14,C.ink);
 text(s,'Codex response line 2','simplified how you switch screens.',20,474,353,26,14,C.ink);
 text(s,'Codex response line 3','The updated mockups are ready.',20,501,353,26,14,C.ink);
 const logs=card(s,'Collapsed Codex tool activity',20,548,353,72);
 text(logs,'Command icon','>_',13,12,44,41,18,C.blue,true);
 text(logs,'Activity summary','4 actions · 3 completed',58,10,282,27,13,C.ink,true);
 text(logs,'Activity state','1 action currently running',58,39,280,21,11,C.muted);
 const composer=card(s,'Codex message composer',20,671,353,79);
 text(composer,'Composer prompt','Message Codex...',14,14,269,48,13,C.muted);
 btn(composer,'Send message','→',292,17,48,46,true);
 nav(s,'Codex');
}
// 06 RECOVERY
{
 const s=board('06 / Recovery / Stream-specific failure',5);status(s);brand(s);
 text(s,'Recovery section caption','CONNECTION STATUS',20,120,277,21,11,C.quiet,true);
 text(s,'Recovery hero','Still connected',20,146,353,45,29,C.ink,true);
 text(s,'Recovery line','One screen needs attention. The rest are ready.',20,193,353,38,12,C.muted);
 const host=card(s,'Host is connected',20,253,353,79);
 dot(host,'Host status success circle',15,22,26,C.goodPale);
 text(host,'Host status check','✓',19,23,20,23,16,C.good,true,'CENTER');
 text(host,'Host online title','Jarvis is online',53,13,278,27,15,C.ink,true);
 text(host,'LAN route','Direct LAN · 3 ms',53,43,260,21,11,C.muted);
 const failure=card(s,'Monitor stream interruption',20,349,353,276);
 const placeholder=box(failure,'Paused preview artwork',13,13,327,101,C.soft,10);
 dot(placeholder,'Playback warning icon',141,25,45,'#FFF4E2','#EBC998');
 text(placeholder,'Warning mark','!',149,27,28,39,22,'#835314',true,'CENTER');
 text(failure,'Failure header','Monitor 1 preview paused',14,132,319,32,18,C.ink,true);
 text(failure,'Failure detail 1','Jarvis is responding, but this screen',14,167,325,24,12,C.muted);
 text(failure,'Failure detail 2','has not sent a fresh frame.',14,192,322,24,12,C.muted);
 btn(failure,'Retry stream','Retry preview',13,224,157,47,true);
 btn(failure,'Switch to a target','Switch view',180,224,160,47,false);
 section(s,'Other available views',644);
 const other=card(s,'Continue with live BlueStacks',20,688,353,69);
 game(other,9,7,73,55,false);
 text(other,'Alternate target','MapleStory Idle',95,9,215,25,14,C.ink,true);
 text(other,'Alternate status','● Live · BlueStacks 1',95,32,219,23,11,C.good,true);
 text(other,'Open alternative','›',321,16,26,31,24,C.blue,true,'CENTER');
 nav(s,'Home');
}
console.log('Built '+p.children.length+' light-first editable artboards.');
