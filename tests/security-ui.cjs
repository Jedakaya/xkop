// No runtime/test dependency: exercise renderers with the documented LuCI DOM contract.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const attack = '<img src=x onerror="globalThis.compromised=true">\'\\"&';
let unsafe = [];
class Element {
  constructor(tag) { this.tag = tag; this.children = []; this.classList = {add(){},remove(){}}; this.style = {}; }
  set innerHTML(value) { if (String(value).includes('<img') || /onchange="[^"\n]*<img/.test(value)) unsafe.push(value); this.children = []; this.html = value; }
  set textContent(value) { this.children = [String(value)]; }
  get textContent() { return this.children.map(x => x instanceof Element ? x.textContent : x).join(''); }
  appendChild(child) { this.children.push(child); return child; }
  replaceChildren(...children) { this.children = children; }
  addEventListener(name, cb) { this['on'+name] = cb; }
  setAttribute(name, value) { this[name] = value; }
}
const elements = {};
const document = {createElement: t=>new Element(t), createTextNode: String,
  getElementById: id => elements[id] || (elements[id] = new Element('div'))};
function E(tag, attrs, children) {
  const node = new Element(tag); Object.assign(node, attrs);
  if (Array.isArray(children)) children.forEach(c=>node.appendChild(c));
  else if (children instanceof Element) node.appendChild(children);
  else if (children != null) node.innerHTML = String(children);
  return node;
}
const context = {document, Node: Element, E, _:s=>s, L:{Class:{extend:x=>x}},
  api:{bytes:String,percent:String}, ui:{createHandlerFn:()=>()=>{}},
  sessionStorage:{getItem:()=>'',setItem(){},removeItem(){}},
  location:{protocol:'https:'}, setInterval(){}, setTimeout(){},
  fetch:()=>Promise.resolve({json:()=>Promise.resolve({ok:false,error:attack})})};
vm.createContext(context);
const html = fs.readFileSync(path.join(root,'client-panel/index.html'),'utf8');
vm.runInContext(html.match(/<script>([\s\S]*?)<\/script>/)[1],context);
context.renderSubs([{id:attack,state:attack,servers:attack,announce:attack}]);
context.renderNodes({alive:attack,total:attack,selected:attack,list:[{tag:attack,state:attack,delay_ms:attack}]});
context.renderRoutes({ok:true,channels:[{id:attack,type:'proxy'}],bindings:[{id:attack,title:attack,channel:attack}]});
const dashboard=fs.readFileSync(path.join(root,'luci-app-xkop/htdocs/luci-static/resources/view/xkop/dashboard.js'),'utf8');
vm.runInContext(dashboard.slice(0,dashboard.indexOf('return L.Class.extend(')),context);
context.renderSubscriptions([{subscription:attack,state:'ready',servers:1,panel:{announce:attack}}],()=>{});
context.line(attack,attack,attack);
context.renderPool({ok:true,selected:attack,nodes:[{tag:attack,state:'dead',last_error:attack,delay_ms:attack,probes:attack}]},()=>{});
context.renderRules({reason:attack});
context.renderRouterWidget({system:{model:attack}});
assert.equal(unsafe.length,0,'external strings must never become HTML in either renderer');
assert.ok(elements.subs.textContent.includes(attack),'announcement stays visible verbatim');
let selected;
context.selectNode=tag=>{selected=tag;};
function descendants(e) { return [e,...e.children.filter(x=>x instanceof Element).flatMap(descendants)]; }
descendants(elements.nodes).find(e=>e.tag==='button').onclick();
assert.equal(selected,attack,'node selection preserves quotes and backslashes without inline JS');
let binding;
context.setRoute=(id,value)=>{binding=[id,value];};
const select=descendants(elements.routes).find(e=>e.tag==='select'); select.value=attack; select.onchange();
assert.deepEqual(binding,[attack,attack],'route identifiers pass through DOM events intact');
let requests=0; context.fetch=()=>{requests++;return Promise.resolve({json:()=>Promise.resolve({ok:false})});};
const commands=[];
const apiSource=fs.readFileSync(path.join(root,'luci-app-xkop/htdocs/luci-static/resources/view/xkop/api.js'),'utf8');
const api=new Function('fs','L',apiSource)({exec:(command,args)=>{commands.push([command,args]);return Promise.resolve({code:0,stdout:'{}'});}},context.L);
api.dashboard();api.explain('example.org');api.select(attack);api.service('stop');api.canary();
assert.deepEqual(commands.map(([command])=>command),['/usr/libexec/xkop-read','/usr/libexec/xkop-read','/usr/bin/xkop','/usr/bin/xkop','/usr/bin/xkop'],'monitoring uses read-only RPC while mutation uses write ACL');
context.location.protocol='http:';
Promise.resolve(context.post('auth',{password:'fixture'})).then(()=>{
  assert.equal(requests,0,'HTTP never sends passwords or tokens');
  console.log('PASS security UI rendering, events and HTTPS transport');
}).catch(e=>{console.error(e);process.exitCode=1;});
