this.Publr=this.Publr||{},this.Publr.Editor=(function(e){Object.defineProperty(e,Symbol.toStringTag,{value:`Module`});var t=`raw-html`,n=e=>typeof e==`object`?{...e}:e,r=e=>typeof e==`string`?e:``,i=[{attr:`data-pb-text`,kind:`text`},{attr:`data-pb-rich`,kind:`rich`},{attr:`data-pb-tag`,kind:`tag`},{attr:`data-pb-image`,kind:`image`},{attr:`data-pb-link`,kind:`link`}],a=i.map(e=>`[${e.attr}]`).join(`,`),o=`[data-pb-text],[data-pb-rich]`,s=`data-pb-children`,c=`data-pb-pattern`,l=`script[type="application/json"][data-pb-settings]`,u=`script[type="application/json"][data-pb-style]`;function d(e){return e.replace(/<\//g,`<\\/`)}function f(e){return String(e).replace(/&/g,`&amp;`).replace(/</g,`&lt;`).replace(/>/g,`&gt;`)}function p(e){return f(e).replace(/"/g,`&quot;`)}function m(){return`b_`+(globalThis.crypto?.randomUUID?.()??Math.random().toString(36).slice(2)).slice(0,8)}function h(e){let t=[...e.querySelectorAll(a)];return e.matches(a)&&t.unshift(e),t.filter(t=>t.closest(`[data-pb-block]`)===e)}function g(e){let t=[...e.querySelectorAll(`[${s}]`)];return e.matches(`[data-pb-children]`)&&t.unshift(e),t.find(t=>t.closest(`[data-pb-block]`)===e)??null}function _(e){return[...e.querySelectorAll(`script[type="application/json"][data-pb-settings]`)].find(t=>t.closest(`[data-pb-block]`)===e)??null}function v(e,t){if(t===`tag`)return e.tagName.toLowerCase();if(t===`link`)return e.getAttribute(`href`)??``;if(t===`image`)return{src:e.getAttribute(`src`)??``,alt:e.getAttribute(`alt`)??``,width:e.getAttribute(`width`)??``,height:e.getAttribute(`height`)??``};let n=e,r=`${l},${u}`;if(e.querySelector(r)){let t=e.cloneNode(!0);for(let e of t.querySelectorAll(r)){let n=e.closest(`[data-pb-block]`);(!n||n===t)&&e.remove()}n=t}return t===`text`?n.textContent??``:n.innerHTML}var y=e=>(e??``).split(/\s+/).filter(Boolean),b={bold:{tag:`b`,match:[`b`,`strong`]},italic:{tag:`i`,match:[`i`,`em`]}},x=Object.keys(b),S=[...x,`link`];function C(e){for(let t of x)if(b[t].match.includes(e))return t;return null}function w(e){let t=[...e.attributes].map(e=>`${e.name}="${p(e.value)}"`).join(` `);return{open:`<a${t?` ${t}`:``}>`,href:e.getAttribute(`href`)??``,target:e.getAttribute(`target`)??``}}function ee(e,t){let n=t===`_blank`?` target="_blank" rel="noopener"`:``;return{open:`<a href="${p(e)}"${n}>`,href:e,target:t}}function T(e){let t=[];return(function e(n,r,i){for(let a of n.childNodes)if(a instanceof Text)for(let e=0;e<a.data.length;e++)t.push({ch:a.data[e],node:a,off:e,marks:new Set(r),link:i});else if(a instanceof Element){let n=a.tagName.toLowerCase(),o=C(n);o?e(a,[...r,o],i):n===`a`?e(a,r,w(a)):t.push({atom:a,marks:new Set(r),link:i})}})(e,[],void 0),t}function E(e,t){let n=-1,r=-1;return e.forEach((e,i)=>{(e.ch==null?t.intersectsNode(e.atom):t.comparePoint(e.node,e.off)===0&&!(e.node===t.endContainer&&e.off===t.endOffset))&&(n<0&&(n=i),r=i+1)}),n<0?null:[n,r]}function te(e){let t=``,n=[],r,i=!1,a=()=>{if(!n.length)return;let e=n.map(e=>e.ch==null?e.atom.outerHTML:f(e.ch)).join(``);t+=r?`${r.open}${e}</a>`:e,n=[]};for(let t of e)i&&(t.link?.open??``)!==(r?.open??``)&&a(),r=t.link,i=!0,n.push(t);return a(),t}function D(e,t=x){if(!t.length)return te(e);let[n,...r]=t,i=b[n].tag,a=``,o=[],s=null,c=()=>{if(!o.length)return;let e=D(o,r);a+=s?`<${i}>${e}</${i}>`:e,o=[]};for(let t of e){let e=t.marks.has(n);s!==null&&e!==s&&c(),s=e,o.push(t)}return c(),a}function O(e,t){let n=Object.fromEntries(x.map(e=>[e,!1]));if(!e||!t)return n;let r=T(e),i=E(r,t);if(!i)return n;let a=r.slice(i[0],i[1]);for(let e of x)n[e]=a.every(t=>t.marks.has(e));return n}function ne(e,t,n){if(!(n in b))return null;let r=n,i=T(e),a=E(i,t);if(!a)return null;let o=i.slice(a[0],a[1]),s=o.every(e=>e.marks.has(r));for(let e of o)s?e.marks.delete(r):e.marks.add(r);return{html:D(i),start:a[0],end:a[1]}}function re(e,t){if(!e||!t)return null;let n=T(e),r=E(n,t);if(!r)return null;let i=n.slice(r[0],r[1]),a=i[0]?.link;return!a||!i.every(e=>e.link?.open===a.open)?null:{href:a.href,target:a.target}}function ie(e,t,n,r){let i=T(e),a=E(i,t);if(!a)return null;let o=ee(n,r);for(let e=a[0];e<a[1];e++)i[e].link=o;return{html:D(i),start:a[0],end:a[1]}}function ae(e,t){let n=T(e),r=E(n,t);if(!r)return null;for(let e=r[0];e<r[1];e++)n[e].link=void 0;return{html:D(n),start:r[0],end:r[1]}}function oe(e,t,n){let r=T(e),i=r[t],a=r[n-1];if(!i||!a)return;let o=document.createRange();i.ch==null?o.setStartBefore(i.atom):o.setStart(i.node,i.off),a.ch==null?o.setEndAfter(a.atom):o.setEnd(a.node,a.off+1);let s=window.getSelection();s?.removeAllRanges(),s?.addRange(o)}var k={tokens:[{name:`font-sans`,value:`ui-sans-serif, system-ui, sans-serif, 'Apple Color Emoji', 'Segoe UI Emoji', 'Segoe UI Symbol', 'Noto Color Emoji'`},{name:`font-serif`,value:`ui-serif, Georgia, Cambria, 'Times New Roman', Times, serif`},{name:`font-mono`,value:`ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace`},{name:`color-red-50`,value:`oklch(97.1% 0.013 17.38)`},{name:`color-red-100`,value:`oklch(93.6% 0.032 17.717)`},{name:`color-red-200`,value:`oklch(88.5% 0.062 18.334)`},{name:`color-red-300`,value:`oklch(80.8% 0.114 19.571)`},{name:`color-red-400`,value:`oklch(70.4% 0.191 22.216)`},{name:`color-red-500`,value:`oklch(63.7% 0.237 25.331)`},{name:`color-red-600`,value:`oklch(57.7% 0.245 27.325)`},{name:`color-red-700`,value:`oklch(50.5% 0.213 27.518)`},{name:`color-red-800`,value:`oklch(44.4% 0.177 26.899)`},{name:`color-red-900`,value:`oklch(39.6% 0.141 25.723)`},{name:`color-red-950`,value:`oklch(25.8% 0.092 26.042)`},{name:`color-orange-50`,value:`oklch(98% 0.016 73.684)`},{name:`color-orange-100`,value:`oklch(95.4% 0.038 75.164)`},{name:`color-orange-200`,value:`oklch(90.1% 0.076 70.697)`},{name:`color-orange-300`,value:`oklch(83.7% 0.128 66.29)`},{name:`color-orange-400`,value:`oklch(75% 0.183 55.934)`},{name:`color-orange-500`,value:`oklch(70.5% 0.213 47.604)`},{name:`color-orange-600`,value:`oklch(64.6% 0.222 41.116)`},{name:`color-orange-700`,value:`oklch(55.3% 0.195 38.402)`},{name:`color-orange-800`,value:`oklch(47% 0.157 37.304)`},{name:`color-orange-900`,value:`oklch(40.8% 0.123 38.172)`},{name:`color-orange-950`,value:`oklch(26.6% 0.079 36.259)`},{name:`color-amber-50`,value:`oklch(98.7% 0.022 95.277)`},{name:`color-amber-100`,value:`oklch(96.2% 0.059 95.617)`},{name:`color-amber-200`,value:`oklch(92.4% 0.12 95.746)`},{name:`color-amber-300`,value:`oklch(87.9% 0.169 91.605)`},{name:`color-amber-400`,value:`oklch(82.8% 0.189 84.429)`},{name:`color-amber-500`,value:`oklch(76.9% 0.188 70.08)`},{name:`color-amber-600`,value:`oklch(66.6% 0.179 58.318)`},{name:`color-amber-700`,value:`oklch(55.5% 0.163 48.998)`},{name:`color-amber-800`,value:`oklch(47.3% 0.137 46.201)`},{name:`color-amber-900`,value:`oklch(41.4% 0.112 45.904)`},{name:`color-amber-950`,value:`oklch(27.9% 0.077 45.635)`},{name:`color-yellow-50`,value:`oklch(98.7% 0.026 102.212)`},{name:`color-yellow-100`,value:`oklch(97.3% 0.071 103.193)`},{name:`color-yellow-200`,value:`oklch(94.5% 0.129 101.54)`},{name:`color-yellow-300`,value:`oklch(90.5% 0.182 98.111)`},{name:`color-yellow-400`,value:`oklch(85.2% 0.199 91.936)`},{name:`color-yellow-500`,value:`oklch(79.5% 0.184 86.047)`},{name:`color-yellow-600`,value:`oklch(68.1% 0.162 75.834)`},{name:`color-yellow-700`,value:`oklch(55.4% 0.135 66.442)`},{name:`color-yellow-800`,value:`oklch(47.6% 0.114 61.907)`},{name:`color-yellow-900`,value:`oklch(42.1% 0.095 57.708)`},{name:`color-yellow-950`,value:`oklch(28.6% 0.066 53.813)`},{name:`color-lime-50`,value:`oklch(98.6% 0.031 120.757)`},{name:`color-lime-100`,value:`oklch(96.7% 0.067 122.328)`},{name:`color-lime-200`,value:`oklch(93.8% 0.127 124.321)`},{name:`color-lime-300`,value:`oklch(89.7% 0.196 126.665)`},{name:`color-lime-400`,value:`oklch(84.1% 0.238 128.85)`},{name:`color-lime-500`,value:`oklch(76.8% 0.233 130.85)`},{name:`color-lime-600`,value:`oklch(64.8% 0.2 131.684)`},{name:`color-lime-700`,value:`oklch(53.2% 0.157 131.589)`},{name:`color-lime-800`,value:`oklch(45.3% 0.124 130.933)`},{name:`color-lime-900`,value:`oklch(40.5% 0.101 131.063)`},{name:`color-lime-950`,value:`oklch(27.4% 0.072 132.109)`},{name:`color-green-50`,value:`oklch(98.2% 0.018 155.826)`},{name:`color-green-100`,value:`oklch(96.2% 0.044 156.743)`},{name:`color-green-200`,value:`oklch(92.5% 0.084 155.995)`},{name:`color-green-300`,value:`oklch(87.1% 0.15 154.449)`},{name:`color-green-400`,value:`oklch(79.2% 0.209 151.711)`},{name:`color-green-500`,value:`oklch(72.3% 0.219 149.579)`},{name:`color-green-600`,value:`oklch(62.7% 0.194 149.214)`},{name:`color-green-700`,value:`oklch(52.7% 0.154 150.069)`},{name:`color-green-800`,value:`oklch(44.8% 0.119 151.328)`},{name:`color-green-900`,value:`oklch(39.3% 0.095 152.535)`},{name:`color-green-950`,value:`oklch(26.6% 0.065 152.934)`},{name:`color-emerald-50`,value:`oklch(97.9% 0.021 166.113)`},{name:`color-emerald-100`,value:`oklch(95% 0.052 163.051)`},{name:`color-emerald-200`,value:`oklch(90.5% 0.093 164.15)`},{name:`color-emerald-300`,value:`oklch(84.5% 0.143 164.978)`},{name:`color-emerald-400`,value:`oklch(76.5% 0.177 163.223)`},{name:`color-emerald-500`,value:`oklch(69.6% 0.17 162.48)`},{name:`color-emerald-600`,value:`oklch(59.6% 0.145 163.225)`},{name:`color-emerald-700`,value:`oklch(50.8% 0.118 165.612)`},{name:`color-emerald-800`,value:`oklch(43.2% 0.095 166.913)`},{name:`color-emerald-900`,value:`oklch(37.8% 0.077 168.94)`},{name:`color-emerald-950`,value:`oklch(26.2% 0.051 172.552)`},{name:`color-teal-50`,value:`oklch(98.4% 0.014 180.72)`},{name:`color-teal-100`,value:`oklch(95.3% 0.051 180.801)`},{name:`color-teal-200`,value:`oklch(91% 0.096 180.426)`},{name:`color-teal-300`,value:`oklch(85.5% 0.138 181.071)`},{name:`color-teal-400`,value:`oklch(77.7% 0.152 181.912)`},{name:`color-teal-500`,value:`oklch(70.4% 0.14 182.503)`},{name:`color-teal-600`,value:`oklch(60% 0.118 184.704)`},{name:`color-teal-700`,value:`oklch(51.1% 0.096 186.391)`},{name:`color-teal-800`,value:`oklch(43.7% 0.078 188.216)`},{name:`color-teal-900`,value:`oklch(38.6% 0.063 188.416)`},{name:`color-teal-950`,value:`oklch(27.7% 0.046 192.524)`},{name:`color-cyan-50`,value:`oklch(98.4% 0.019 200.873)`},{name:`color-cyan-100`,value:`oklch(95.6% 0.045 203.388)`},{name:`color-cyan-200`,value:`oklch(91.7% 0.08 205.041)`},{name:`color-cyan-300`,value:`oklch(86.5% 0.127 207.078)`},{name:`color-cyan-400`,value:`oklch(78.9% 0.154 211.53)`},{name:`color-cyan-500`,value:`oklch(71.5% 0.143 215.221)`},{name:`color-cyan-600`,value:`oklch(60.9% 0.126 221.723)`},{name:`color-cyan-700`,value:`oklch(52% 0.105 223.128)`},{name:`color-cyan-800`,value:`oklch(45% 0.085 224.283)`},{name:`color-cyan-900`,value:`oklch(39.8% 0.07 227.392)`},{name:`color-cyan-950`,value:`oklch(30.2% 0.056 229.695)`},{name:`color-sky-50`,value:`oklch(97.7% 0.013 236.62)`},{name:`color-sky-100`,value:`oklch(95.1% 0.026 236.824)`},{name:`color-sky-200`,value:`oklch(90.1% 0.058 230.902)`},{name:`color-sky-300`,value:`oklch(82.8% 0.111 230.318)`},{name:`color-sky-400`,value:`oklch(74.6% 0.16 232.661)`},{name:`color-sky-500`,value:`oklch(68.5% 0.169 237.323)`},{name:`color-sky-600`,value:`oklch(58.8% 0.158 241.966)`},{name:`color-sky-700`,value:`oklch(50% 0.134 242.749)`},{name:`color-sky-800`,value:`oklch(44.3% 0.11 240.79)`},{name:`color-sky-900`,value:`oklch(39.1% 0.09 240.876)`},{name:`color-sky-950`,value:`oklch(29.3% 0.066 243.157)`},{name:`color-blue-50`,value:`oklch(97% 0.014 254.604)`},{name:`color-blue-100`,value:`oklch(93.2% 0.032 255.585)`},{name:`color-blue-200`,value:`oklch(88.2% 0.059 254.128)`},{name:`color-blue-300`,value:`oklch(80.9% 0.105 251.813)`},{name:`color-blue-400`,value:`oklch(70.7% 0.165 254.624)`},{name:`color-blue-500`,value:`oklch(62.3% 0.214 259.815)`},{name:`color-blue-600`,value:`oklch(54.6% 0.245 262.881)`},{name:`color-blue-700`,value:`oklch(48.8% 0.243 264.376)`},{name:`color-blue-800`,value:`oklch(42.4% 0.199 265.638)`},{name:`color-blue-900`,value:`oklch(37.9% 0.146 265.522)`},{name:`color-blue-950`,value:`oklch(28.2% 0.091 267.935)`},{name:`color-indigo-50`,value:`oklch(96.2% 0.018 272.314)`},{name:`color-indigo-100`,value:`oklch(93% 0.034 272.788)`},{name:`color-indigo-200`,value:`oklch(87% 0.065 274.039)`},{name:`color-indigo-300`,value:`oklch(78.5% 0.115 274.713)`},{name:`color-indigo-400`,value:`oklch(67.3% 0.182 276.935)`},{name:`color-indigo-500`,value:`oklch(58.5% 0.233 277.117)`},{name:`color-indigo-600`,value:`oklch(51.1% 0.262 276.966)`},{name:`color-indigo-700`,value:`oklch(45.7% 0.24 277.023)`},{name:`color-indigo-800`,value:`oklch(39.8% 0.195 277.366)`},{name:`color-indigo-900`,value:`oklch(35.9% 0.144 278.697)`},{name:`color-indigo-950`,value:`oklch(25.7% 0.09 281.288)`},{name:`color-violet-50`,value:`oklch(96.9% 0.016 293.756)`},{name:`color-violet-100`,value:`oklch(94.3% 0.029 294.588)`},{name:`color-violet-200`,value:`oklch(89.4% 0.057 293.283)`},{name:`color-violet-300`,value:`oklch(81.1% 0.111 293.571)`},{name:`color-violet-400`,value:`oklch(70.2% 0.183 293.541)`},{name:`color-violet-500`,value:`oklch(60.6% 0.25 292.717)`},{name:`color-violet-600`,value:`oklch(54.1% 0.281 293.009)`},{name:`color-violet-700`,value:`oklch(49.1% 0.27 292.581)`},{name:`color-violet-800`,value:`oklch(43.2% 0.232 292.759)`},{name:`color-violet-900`,value:`oklch(38% 0.189 293.745)`},{name:`color-violet-950`,value:`oklch(28.3% 0.141 291.089)`},{name:`color-purple-50`,value:`oklch(97.7% 0.014 308.299)`},{name:`color-purple-100`,value:`oklch(94.6% 0.033 307.174)`},{name:`color-purple-200`,value:`oklch(90.2% 0.063 306.703)`},{name:`color-purple-300`,value:`oklch(82.7% 0.119 306.383)`},{name:`color-purple-400`,value:`oklch(71.4% 0.203 305.504)`},{name:`color-purple-500`,value:`oklch(62.7% 0.265 303.9)`},{name:`color-purple-600`,value:`oklch(55.8% 0.288 302.321)`},{name:`color-purple-700`,value:`oklch(49.6% 0.265 301.924)`},{name:`color-purple-800`,value:`oklch(43.8% 0.218 303.724)`},{name:`color-purple-900`,value:`oklch(38.1% 0.176 304.987)`},{name:`color-purple-950`,value:`oklch(29.1% 0.149 302.717)`},{name:`color-fuchsia-50`,value:`oklch(97.7% 0.017 320.058)`},{name:`color-fuchsia-100`,value:`oklch(95.2% 0.037 318.852)`},{name:`color-fuchsia-200`,value:`oklch(90.3% 0.076 319.62)`},{name:`color-fuchsia-300`,value:`oklch(83.3% 0.145 321.434)`},{name:`color-fuchsia-400`,value:`oklch(74% 0.238 322.16)`},{name:`color-fuchsia-500`,value:`oklch(66.7% 0.295 322.15)`},{name:`color-fuchsia-600`,value:`oklch(59.1% 0.293 322.896)`},{name:`color-fuchsia-700`,value:`oklch(51.8% 0.253 323.949)`},{name:`color-fuchsia-800`,value:`oklch(45.2% 0.211 324.591)`},{name:`color-fuchsia-900`,value:`oklch(40.1% 0.17 325.612)`},{name:`color-fuchsia-950`,value:`oklch(29.3% 0.136 325.661)`},{name:`color-pink-50`,value:`oklch(97.1% 0.014 343.198)`},{name:`color-pink-100`,value:`oklch(94.8% 0.028 342.258)`},{name:`color-pink-200`,value:`oklch(89.9% 0.061 343.231)`},{name:`color-pink-300`,value:`oklch(82.3% 0.12 346.018)`},{name:`color-pink-400`,value:`oklch(71.8% 0.202 349.761)`},{name:`color-pink-500`,value:`oklch(65.6% 0.241 354.308)`},{name:`color-pink-600`,value:`oklch(59.2% 0.249 0.584)`},{name:`color-pink-700`,value:`oklch(52.5% 0.223 3.958)`},{name:`color-pink-800`,value:`oklch(45.9% 0.187 3.815)`},{name:`color-pink-900`,value:`oklch(40.8% 0.153 2.432)`},{name:`color-pink-950`,value:`oklch(28.4% 0.109 3.907)`},{name:`color-rose-50`,value:`oklch(96.9% 0.015 12.422)`},{name:`color-rose-100`,value:`oklch(94.1% 0.03 12.58)`},{name:`color-rose-200`,value:`oklch(89.2% 0.058 10.001)`},{name:`color-rose-300`,value:`oklch(81% 0.117 11.638)`},{name:`color-rose-400`,value:`oklch(71.2% 0.194 13.428)`},{name:`color-rose-500`,value:`oklch(64.5% 0.246 16.439)`},{name:`color-rose-600`,value:`oklch(58.6% 0.253 17.585)`},{name:`color-rose-700`,value:`oklch(51.4% 0.222 16.935)`},{name:`color-rose-800`,value:`oklch(45.5% 0.188 13.697)`},{name:`color-rose-900`,value:`oklch(41% 0.159 10.272)`},{name:`color-rose-950`,value:`oklch(27.1% 0.105 12.094)`},{name:`color-slate-50`,value:`oklch(98.4% 0.003 247.858)`},{name:`color-slate-100`,value:`oklch(96.8% 0.007 247.896)`},{name:`color-slate-200`,value:`oklch(92.9% 0.013 255.508)`},{name:`color-slate-300`,value:`oklch(86.9% 0.022 252.894)`},{name:`color-slate-400`,value:`oklch(70.4% 0.04 256.788)`},{name:`color-slate-500`,value:`oklch(55.4% 0.046 257.417)`},{name:`color-slate-600`,value:`oklch(44.6% 0.043 257.281)`},{name:`color-slate-700`,value:`oklch(37.2% 0.044 257.287)`},{name:`color-slate-800`,value:`oklch(27.9% 0.041 260.031)`},{name:`color-slate-900`,value:`oklch(20.8% 0.042 265.755)`},{name:`color-slate-950`,value:`oklch(12.9% 0.042 264.695)`},{name:`color-gray-50`,value:`oklch(98.5% 0.002 247.839)`},{name:`color-gray-100`,value:`oklch(96.7% 0.003 264.542)`},{name:`color-gray-200`,value:`oklch(92.8% 0.006 264.531)`},{name:`color-gray-300`,value:`oklch(87.2% 0.01 258.338)`},{name:`color-gray-400`,value:`oklch(70.7% 0.022 261.325)`},{name:`color-gray-500`,value:`oklch(55.1% 0.027 264.364)`},{name:`color-gray-600`,value:`oklch(44.6% 0.03 256.802)`},{name:`color-gray-700`,value:`oklch(37.3% 0.034 259.733)`},{name:`color-gray-800`,value:`oklch(27.8% 0.033 256.848)`},{name:`color-gray-900`,value:`oklch(21% 0.034 264.665)`},{name:`color-gray-950`,value:`oklch(13% 0.028 261.692)`},{name:`color-zinc-50`,value:`oklch(98.5% 0 0)`},{name:`color-zinc-100`,value:`oklch(96.7% 0.001 286.375)`},{name:`color-zinc-200`,value:`oklch(92% 0.004 286.32)`},{name:`color-zinc-300`,value:`oklch(87.1% 0.006 286.286)`},{name:`color-zinc-400`,value:`oklch(70.5% 0.015 286.067)`},{name:`color-zinc-500`,value:`oklch(55.2% 0.016 285.938)`},{name:`color-zinc-600`,value:`oklch(44.2% 0.017 285.786)`},{name:`color-zinc-700`,value:`oklch(37% 0.013 285.805)`},{name:`color-zinc-800`,value:`oklch(27.4% 0.006 286.033)`},{name:`color-zinc-900`,value:`oklch(21% 0.006 285.885)`},{name:`color-zinc-950`,value:`oklch(14.1% 0.005 285.823)`},{name:`color-neutral-50`,value:`oklch(98.5% 0 0)`},{name:`color-neutral-100`,value:`oklch(97% 0 0)`},{name:`color-neutral-200`,value:`oklch(92.2% 0 0)`},{name:`color-neutral-300`,value:`oklch(87% 0 0)`},{name:`color-neutral-400`,value:`oklch(70.8% 0 0)`},{name:`color-neutral-500`,value:`oklch(55.6% 0 0)`},{name:`color-neutral-600`,value:`oklch(43.9% 0 0)`},{name:`color-neutral-700`,value:`oklch(37.1% 0 0)`},{name:`color-neutral-800`,value:`oklch(26.9% 0 0)`},{name:`color-neutral-900`,value:`oklch(20.5% 0 0)`},{name:`color-neutral-950`,value:`oklch(14.5% 0 0)`},{name:`color-stone-50`,value:`oklch(98.5% 0.001 106.423)`},{name:`color-stone-100`,value:`oklch(97% 0.001 106.424)`},{name:`color-stone-200`,value:`oklch(92.3% 0.003 48.717)`},{name:`color-stone-300`,value:`oklch(86.9% 0.005 56.366)`},{name:`color-stone-400`,value:`oklch(70.9% 0.01 56.259)`},{name:`color-stone-500`,value:`oklch(55.3% 0.013 58.071)`},{name:`color-stone-600`,value:`oklch(44.4% 0.011 73.639)`},{name:`color-stone-700`,value:`oklch(37.4% 0.01 67.558)`},{name:`color-stone-800`,value:`oklch(26.8% 0.007 34.298)`},{name:`color-stone-900`,value:`oklch(21.6% 0.006 56.043)`},{name:`color-stone-950`,value:`oklch(14.7% 0.004 49.25)`},{name:`color-mauve-50`,value:`oklch(98.5% 0 0)`},{name:`color-mauve-100`,value:`oklch(96% 0.003 325.6)`},{name:`color-mauve-200`,value:`oklch(92.2% 0.005 325.62)`},{name:`color-mauve-300`,value:`oklch(86.5% 0.012 325.68)`},{name:`color-mauve-400`,value:`oklch(71.1% 0.019 323.02)`},{name:`color-mauve-500`,value:`oklch(54.2% 0.034 322.5)`},{name:`color-mauve-600`,value:`oklch(43.5% 0.029 321.78)`},{name:`color-mauve-700`,value:`oklch(36.4% 0.029 323.89)`},{name:`color-mauve-800`,value:`oklch(26.3% 0.024 320.12)`},{name:`color-mauve-900`,value:`oklch(21.2% 0.019 322.12)`},{name:`color-mauve-950`,value:`oklch(14.5% 0.008 326)`},{name:`color-olive-50`,value:`oklch(98.8% 0.003 106.5)`},{name:`color-olive-100`,value:`oklch(96.6% 0.005 106.5)`},{name:`color-olive-200`,value:`oklch(93% 0.007 106.5)`},{name:`color-olive-300`,value:`oklch(88% 0.011 106.6)`},{name:`color-olive-400`,value:`oklch(73.7% 0.021 106.9)`},{name:`color-olive-500`,value:`oklch(58% 0.031 107.3)`},{name:`color-olive-600`,value:`oklch(46.6% 0.025 107.3)`},{name:`color-olive-700`,value:`oklch(39.4% 0.023 107.4)`},{name:`color-olive-800`,value:`oklch(28.6% 0.016 107.4)`},{name:`color-olive-900`,value:`oklch(22.8% 0.013 107.4)`},{name:`color-olive-950`,value:`oklch(15.3% 0.006 107.1)`},{name:`color-mist-50`,value:`oklch(98.7% 0.002 197.1)`},{name:`color-mist-100`,value:`oklch(96.3% 0.002 197.1)`},{name:`color-mist-200`,value:`oklch(92.5% 0.005 214.3)`},{name:`color-mist-300`,value:`oklch(87.2% 0.007 219.6)`},{name:`color-mist-400`,value:`oklch(72.3% 0.014 214.4)`},{name:`color-mist-500`,value:`oklch(56% 0.021 213.5)`},{name:`color-mist-600`,value:`oklch(45% 0.017 213.2)`},{name:`color-mist-700`,value:`oklch(37.8% 0.015 216)`},{name:`color-mist-800`,value:`oklch(27.5% 0.011 216.9)`},{name:`color-mist-900`,value:`oklch(21.8% 0.008 223.9)`},{name:`color-mist-950`,value:`oklch(14.8% 0.004 228.8)`},{name:`color-taupe-50`,value:`oklch(98.6% 0.002 67.8)`},{name:`color-taupe-100`,value:`oklch(96% 0.002 17.2)`},{name:`color-taupe-200`,value:`oklch(92.2% 0.005 34.3)`},{name:`color-taupe-300`,value:`oklch(86.8% 0.007 39.5)`},{name:`color-taupe-400`,value:`oklch(71.4% 0.014 41.2)`},{name:`color-taupe-500`,value:`oklch(54.7% 0.021 43.1)`},{name:`color-taupe-600`,value:`oklch(43.8% 0.017 39.3)`},{name:`color-taupe-700`,value:`oklch(36.7% 0.016 35.7)`},{name:`color-taupe-800`,value:`oklch(26.8% 0.011 36.5)`},{name:`color-taupe-900`,value:`oklch(21.4% 0.009 43.1)`},{name:`color-taupe-950`,value:`oklch(14.7% 0.004 49.3)`},{name:`color-black`,value:`#000`},{name:`color-white`,value:`#fff`},{name:`spacing`,value:`0.25rem`},{name:`breakpoint-sm`,value:`40rem`},{name:`breakpoint-md`,value:`48rem`},{name:`breakpoint-lg`,value:`64rem`},{name:`breakpoint-xl`,value:`80rem`},{name:`breakpoint-2xl`,value:`96rem`},{name:`container-3xs`,value:`16rem`},{name:`container-2xs`,value:`18rem`},{name:`container-xs`,value:`20rem`},{name:`container-sm`,value:`24rem`},{name:`container-md`,value:`28rem`},{name:`container-lg`,value:`32rem`},{name:`container-xl`,value:`36rem`},{name:`container-2xl`,value:`42rem`},{name:`container-3xl`,value:`48rem`},{name:`container-4xl`,value:`56rem`},{name:`container-5xl`,value:`64rem`},{name:`container-6xl`,value:`72rem`},{name:`container-7xl`,value:`80rem`},{name:`container-screen-sm`,value:`40rem`},{name:`container-screen-md`,value:`48rem`},{name:`container-screen-lg`,value:`64rem`},{name:`container-screen-xl`,value:`80rem`},{name:`container-screen-2xl`,value:`96rem`},{name:`text-xs`,value:`0.75rem`},{name:`text-xs--line-height`,value:`calc(1 / 0.75)`},{name:`text-sm`,value:`0.875rem`},{name:`text-sm--line-height`,value:`calc(1.25 / 0.875)`},{name:`text-base`,value:`1rem`},{name:`text-base--line-height`,value:`calc(1.5 / 1)`},{name:`text-lg`,value:`1.125rem`},{name:`text-lg--line-height`,value:`calc(1.75 / 1.125)`},{name:`text-xl`,value:`1.25rem`},{name:`text-xl--line-height`,value:`calc(1.75 / 1.25)`},{name:`text-2xl`,value:`1.5rem`},{name:`text-2xl--line-height`,value:`calc(2 / 1.5)`},{name:`text-3xl`,value:`1.875rem`},{name:`text-3xl--line-height`,value:`calc(2.25 / 1.875)`},{name:`text-4xl`,value:`2.25rem`},{name:`text-4xl--line-height`,value:`calc(2.5 / 2.25)`},{name:`text-5xl`,value:`3rem`},{name:`text-5xl--line-height`,value:`1`},{name:`text-6xl`,value:`3.75rem`},{name:`text-6xl--line-height`,value:`1`},{name:`text-7xl`,value:`4.5rem`},{name:`text-7xl--line-height`,value:`1`},{name:`text-8xl`,value:`6rem`},{name:`text-8xl--line-height`,value:`1`},{name:`text-9xl`,value:`8rem`},{name:`text-9xl--line-height`,value:`1`},{name:`font-weight-thin`,value:`100`},{name:`font-weight-extralight`,value:`200`},{name:`font-weight-light`,value:`300`},{name:`font-weight-normal`,value:`400`},{name:`font-weight-medium`,value:`500`},{name:`font-weight-semibold`,value:`600`},{name:`font-weight-bold`,value:`700`},{name:`font-weight-extrabold`,value:`800`},{name:`font-weight-black`,value:`900`},{name:`tracking-tighter`,value:`-0.05em`},{name:`tracking-tight`,value:`-0.025em`},{name:`tracking-normal`,value:`0em`},{name:`tracking-wide`,value:`0.025em`},{name:`tracking-wider`,value:`0.05em`},{name:`tracking-widest`,value:`0.1em`},{name:`leading-tight`,value:`1.25`},{name:`leading-snug`,value:`1.375`},{name:`leading-normal`,value:`1.5`},{name:`leading-relaxed`,value:`1.625`},{name:`leading-loose`,value:`2`},{name:`radius-xs`,value:`0.125rem`},{name:`radius-sm`,value:`0.25rem`},{name:`radius-md`,value:`0.375rem`},{name:`radius-lg`,value:`0.5rem`},{name:`radius-xl`,value:`0.75rem`},{name:`radius-2xl`,value:`1rem`},{name:`radius-3xl`,value:`1.5rem`},{name:`radius-4xl`,value:`2rem`},{name:`shadow-2xs`,value:`0 1px rgb(0 0 0 / 0.05)`},{name:`shadow-xs`,value:`0 1px 2px 0 rgb(0 0 0 / 0.05)`},{name:`shadow-sm`,value:`0 1px 3px 0 rgb(0 0 0 / 0.1), 0 1px 2px -1px rgb(0 0 0 / 0.1)`},{name:`shadow-md`,value:`0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1)`},{name:`shadow-lg`,value:`0 10px 15px -3px rgb(0 0 0 / 0.1), 0 4px 6px -4px rgb(0 0 0 / 0.1)`},{name:`shadow-xl`,value:`0 20px 25px -5px rgb(0 0 0 / 0.1), 0 8px 10px -6px rgb(0 0 0 / 0.1)`},{name:`shadow-2xl`,value:`0 25px 50px -12px rgb(0 0 0 / 0.25)`},{name:`inset-shadow-2xs`,value:`inset 0 1px rgb(0 0 0 / 0.05)`},{name:`inset-shadow-xs`,value:`inset 0 1px 1px rgb(0 0 0 / 0.05)`},{name:`inset-shadow-sm`,value:`inset 0 2px 4px rgb(0 0 0 / 0.05)`},{name:`drop-shadow-xs`,value:`0 1px 1px rgb(0 0 0 / 0.05)`},{name:`drop-shadow-sm`,value:`0 1px 2px rgb(0 0 0 / 0.15)`},{name:`drop-shadow-md`,value:`0 3px 3px rgb(0 0 0 / 0.12)`},{name:`drop-shadow-lg`,value:`0 4px 4px rgb(0 0 0 / 0.15)`},{name:`drop-shadow-xl`,value:`0 9px 7px rgb(0 0 0 / 0.1)`},{name:`drop-shadow-2xl`,value:`0 25px 25px rgb(0 0 0 / 0.15)`},{name:`text-shadow-2xs`,value:`0px 1px 0px rgb(0 0 0 / 0.15)`},{name:`text-shadow-xs`,value:`0px 1px 1px rgb(0 0 0 / 0.2)`},{name:`text-shadow-sm`,value:`0px 1px 0px rgb(0 0 0 / 0.075), 0px 1px 1px rgb(0 0 0 / 0.075), 0px 2px 2px rgb(0 0 0 / 0.075)`},{name:`text-shadow-md`,value:`0px 1px 1px rgb(0 0 0 / 0.1), 0px 1px 2px rgb(0 0 0 / 0.1), 0px 2px 4px rgb(0 0 0 / 0.1)`},{name:`text-shadow-lg`,value:`0px 1px 2px rgb(0 0 0 / 0.1), 0px 3px 2px rgb(0 0 0 / 0.1), 0px 4px 8px rgb(0 0 0 / 0.1)`},{name:`ease-in`,value:`cubic-bezier(0.4, 0, 1, 1)`},{name:`ease-out`,value:`cubic-bezier(0, 0, 0.2, 1)`},{name:`ease-in-out`,value:`cubic-bezier(0.4, 0, 0.2, 1)`},{name:`animate-spin`,value:`spin 1s linear infinite`},{name:`animate-ping`,value:`ping 1s cubic-bezier(0, 0, 0.2, 1) infinite`},{name:`animate-pulse`,value:`pulse 2s cubic-bezier(0.4, 0, 0.6, 1) infinite`},{name:`animate-bounce`,value:`bounce 1s infinite`},{name:`blur-xs`,value:`4px`},{name:`blur-sm`,value:`8px`},{name:`blur-md`,value:`12px`},{name:`blur-lg`,value:`16px`},{name:`blur-xl`,value:`24px`},{name:`blur-2xl`,value:`40px`},{name:`blur-3xl`,value:`64px`},{name:`perspective-dramatic`,value:`100px`},{name:`perspective-near`,value:`300px`},{name:`perspective-normal`,value:`500px`},{name:`perspective-midrange`,value:`800px`},{name:`perspective-distant`,value:`1200px`},{name:`aspect-video`,value:`16 / 9`},{name:`default-transition-duration`,value:`150ms`},{name:`default-transition-timing-function`,value:`cubic-bezier(0.4, 0, 0.2, 1)`},{name:`default-font-family`,value:`--theme(--font-sans, initial)`},{name:`default-font-feature-settings`,value:`--theme(--font-sans--font-feature-settings, initial)`},{name:`default-font-variation-settings`,value:`--theme(--font-sans--font-variation-settings, initial)`},{name:`default-mono-font-family`,value:`--theme(--font-mono, initial)`},{name:`default-mono-font-feature-settings`,value:`--theme(--font-mono--font-feature-settings, initial)`},{name:`default-mono-font-variation-settings`,value:`--theme(--font-mono--font-variation-settings, initial)`}]},se=k,A=()=>se;function ce(e){se=e??k}var j=new WeakMap;function M(e){let t=j.get(e);return t||(t=new Map(e.tokens.map(e=>[e.name,e.value])),j.set(e,t)),t}function le(e,t){return M(e).get(t)}function N(e,t){return M(e).has(t)}function P(e){return{tokens:Object.entries(e).map(([e,t])=>({name:e,value:t}))}}function F(e,t,n=[]){let r=[];for(let i of e.tokens)!i.name.startsWith(t)||i.name.includes(`--`)||n.some(e=>i.name.startsWith(e))||r.push({key:i.name.slice(t.length),value:i.value});return r}var ue=e=>F(e,`text-`,[`text-shadow-`]);function I(e){return F(e,`color-`).map(e=>{let t=/^(.+)-(\d+)$/.exec(e.key);return t?{...e,family:t[1],step:t[2]}:{...e,family:e.key}})}var de=e=>F(e,`radius-`),fe=e=>F(e,`leading-`),L=e=>F(e,`tracking-`),R=e=>le(e,`spacing`),pe=[`0`,`1`,`2`,`4`,`6`,`8`,`12`,`16`],me=[`1`,`2`,`4`,`8`];function z(e){let t=[];for(let n of e.matchAll(/@theme[^{]*\{([^}]*)\}/g))for(let e of n[1].matchAll(/--([a-zA-Z0-9_-]+)\s*:\s*([^;]+);/g))t.push({name:e[1],value:e[2].trim()});return t.length?{tokens:t}:null}function he(e,t=`@theme`){return`${t} {\n${e.tokens.map(e=>`  --${e.name}: ${e.value};`).join(`
`)}\n}`}var ge=e=>e===!0||!!e&&typeof e==`object`,_e=[{key:`underline`,label:`U`,class:`underline`},{key:`strike`,label:`S`,class:`line-through`}],ve=[{key:`upper`,label:`AB`,class:`uppercase`},{key:`lower`,label:`ab`,class:`lowercase`},{key:`caps`,label:`Ab`,class:`capitalize`}],ye=[{key:`left`,label:`Left`,class:`text-left`},{key:`center`,label:`Center`,class:`text-center`},{key:`right`,label:`Right`,class:`text-right`},{key:`justify`,label:`Justify`,class:`text-justify`}],be=[{key:`normal`,label:`Regular`,class:`font-normal`},{key:`medium`,label:`Medium`,class:`font-medium`},{key:`semibold`,label:`Semibold`,class:`font-semibold`},{key:`bold`,label:`Bold`,class:`font-bold`}],xe=[{key:`normal`,label:`Regular`,class:`not-italic`},{key:`italic`,label:`Italic`,class:`italic`}],B=[{key:`start`,label:`Start`,class:`justify-start`},{key:`center`,label:`Center`,class:`justify-center`},{key:`end`,label:`End`,class:`justify-end`},{key:`between`,label:`Between`,class:`justify-between`},{key:`around`,label:`Around`,class:`justify-around`},{key:`evenly`,label:`Evenly`,class:`justify-evenly`}],Se=[{key:`start`,label:`Start`,class:`items-start`},{key:`center`,label:`Center`,class:`items-center`},{key:`end`,label:`End`,class:`items-end`},{key:`stretch`,label:`Stretch`,class:`items-stretch`},{key:`baseline`,label:`Baseline`,class:`items-baseline`}],Ce=[{key:`solid`,label:`Solid`,class:`border-solid`},{key:`dashed`,label:`Dashed`,class:`border-dashed`},{key:`dotted`,label:`Dotted`,class:`border-dotted`},{key:`double`,label:`Double`,class:`border-double`},{key:`none`,label:`None`,class:`border-none`}],V=[{key:`nowrap`,label:`No wrap`,class:`flex-nowrap`},{key:`wrap`,label:`Wrap`,class:`flex-wrap`},{key:`reverse`,label:`Reverse`,class:`flex-wrap-reverse`}],we=Object.fromEntries([..._e,...ve].map(e=>[e.key,e.class])),Te=/^\d+(\.\d+)?$/,Ee=e=>e.trim().replace(/\s+/g,`_`),H=e=>(t,n)=>t?N(n,`color-${t}`)?`${e}-${t}`:`${e}-[${Ee(t)}]`:null,De=(e,t)=>(n,r)=>n?N(r,`${t}-${n}`)?`${e}-${n}`:`${e}-[${Ee(n)}]`:null,U=e=>t=>t?Te.test(t)?`${e}-${t}`:`${e}-[${Ee(t)}]`:null,Oe=e=>t=>t?e.find(e=>e.key===t)?.class??null:null,ke=e=>t=>t?Te.test(t)?`${e}-${t}`:`${e}-[${Ee(t)}]`:null,Ae=e=>e?/^(?:[1-9]|1[0-2])$/.test(e)?`grid-cols-${e}`:`grid-cols-[${Ee(e)}]`:null,W=[{key:`auto`,class:`aspect-auto`},{key:`square`,class:`aspect-square`},{key:`video`,class:`aspect-video`}],je={fontSize:{panel:`typography`,toClass:De(`text`,`text`)},textAlign:{panel:`typography`,toClass:Oe(ye)},fontWeight:{panel:`typography`,toClass:Oe(be)},fontStyle:{panel:`typography`,toClass:Oe(xe)},textColor:{panel:`color`,toClass:H(`text`)},backgroundColor:{panel:`color`,toClass:H(`bg`)},padding:{panel:`spacing`,toClass:U(`p`)},paddingTop:{panel:`spacing`,toClass:U(`pt`)},paddingRight:{panel:`spacing`,toClass:U(`pr`)},paddingBottom:{panel:`spacing`,toClass:U(`pb`)},paddingLeft:{panel:`spacing`,toClass:U(`pl`)},margin:{panel:`spacing`,toClass:U(`m`)},marginTop:{panel:`spacing`,toClass:U(`mt`)},marginRight:{panel:`spacing`,toClass:U(`mr`)},marginBottom:{panel:`spacing`,toClass:U(`mb`)},marginLeft:{panel:`spacing`,toClass:U(`ml`)},width:{panel:`dimensions`,toClass:ke(`w`)},height:{panel:`dimensions`,toClass:ke(`h`)},minHeight:{panel:`dimensions`,toClass:ke(`min-h`)},minWidth:{panel:`dimensions`,toClass:ke(`min-w`)},flexBasis:{panel:`dimensions`,toClass:ke(`basis`)},aspectRatio:{panel:`dimensions`,toClass:e=>Oe(W)(e)??(e?`aspect-[${Ee(e)}]`:null)},gap:{panel:`layout`,toClass:U(`gap`)},rowGap:{panel:`layout`,toClass:U(`gap-y`)},columnGap:{panel:`layout`,toClass:U(`gap-x`)},justifyContent:{panel:`layout`,toClass:Oe(B)},alignItems:{panel:`layout`,toClass:Oe(Se)},flexWrap:{panel:`layout`,toClass:Oe(V)},gridColumns:{panel:`layout`,toClass:Ae},borderWidth:{panel:`border`,toClass:e=>e?e===`1`?`border`:Te.test(e)?`border-${e}`:`border-[${Ee(e)}]`:null},borderColor:{panel:`border`,toClass:H(`border`)},borderRadius:{panel:`border`,toClass:De(`rounded`,`radius`)},borderStyle:{panel:`border`,toClass:Oe(Ce)},lineHeight:{panel:`typography`,toClass:De(`leading`,`leading`)},letterSpacing:{panel:`typography`,toClass:De(`tracking`,`tracking`)},decoration:{panel:`typography`,toClass:e=>e?we[e]??null:null},letterCase:{panel:`typography`,toClass:e=>e?we[e]??null:null}},Me={fontSize:e=>e.typography?.fontSize,textAlign:e=>e.typography?.textAlign,fontWeight:e=>e.typography?.fontWeight,fontStyle:e=>e.typography?.fontStyle,lineHeight:e=>e.typography?.lineHeight,letterSpacing:e=>e.typography?.letterSpacing,decoration:e=>e.typography?.decoration,letterCase:e=>e.typography?.letterCase,textColor:e=>e.color?.text,backgroundColor:e=>e.color?.background,padding:e=>e.spacing?.padding,paddingTop:e=>e.spacing?.paddingTop,paddingRight:e=>e.spacing?.paddingRight,paddingBottom:e=>e.spacing?.paddingBottom,paddingLeft:e=>e.spacing?.paddingLeft,margin:e=>e.spacing?.margin,marginTop:e=>e.spacing?.marginTop,marginRight:e=>e.spacing?.marginRight,marginBottom:e=>e.spacing?.marginBottom,marginLeft:e=>e.spacing?.marginLeft,width:e=>e.dimensions?.width,height:e=>e.dimensions?.height,minHeight:e=>e.dimensions?.minHeight,minWidth:e=>e.dimensions?.minWidth,flexBasis:e=>e.dimensions?.flexBasis,aspectRatio:e=>e.dimensions?.aspectRatio,gap:e=>e.layout?.gap,rowGap:e=>e.layout?.rowGap,columnGap:e=>e.layout?.columnGap,justifyContent:e=>e.layout?.justifyContent,alignItems:e=>e.layout?.alignItems,flexWrap:e=>e.layout?.flexWrap,gridColumns:e=>e.layout?.gridColumns,borderWidth:e=>e.border?.width,borderColor:e=>e.border?.color,borderRadius:e=>e.border?.radius,borderStyle:e=>e.border?.style};function Ne(e,t){return!e||!t?[]:(e.find(e=>e.name===t)?.class??``).split(/\s+/).filter(Boolean)}function Pe(e,t=A()){if(!e)return[];let n=[];for(let[r,i]of Object.entries(e)){let e=je[r]?.toClass(i,t);e&&n.push(e)}return n}function Fe(e,t){return!!e&&ge(Me[t]?.(e))}var Ie=(e,t)=>t.startsWith(`${e}-[`)&&t.endsWith(`]`)?t.slice(e.length+2,-1).replaceAll(`_`,` `):null,Le=/^(#|rgb|hsl|oklch|oklab|color\(|var\()/,Re=(e,t,n)=>(r,i)=>{if(r.startsWith(`${e}-`)){let n=r.slice(e.length+1);if(!n.startsWith(`[`)&&N(i,`${t}-${n}`))return n}let a=Ie(e,r);return a!==null&&(n===void 0||Le.test(a)===n)?a:null},ze=e=>(t,n)=>{if(t.startsWith(`${e}-`)){let r=t.slice(e.length+1);if(!r.startsWith(`[`)&&N(n,`color-${r}`))return r}let r=Ie(e,t);return r!==null&&Le.test(r)?r:null},G=e=>t=>{let n=RegExp(`^${e}-(\\d+(?:\\.\\d+)?)$`).exec(t);return n?n[1]:Ie(e,t)},Be=e=>t=>e.find(e=>e.class===t)?.key??null,Ve={fontSize:Re(`text`,`text`,!1),textAlign:Be(ye),fontWeight:Be(be),fontStyle:Be(xe),textColor:ze(`text`),backgroundColor:ze(`bg`),padding:G(`p`),paddingTop:G(`pt`),paddingRight:G(`pr`),paddingBottom:G(`pb`),paddingLeft:G(`pl`),margin:G(`m`),marginTop:G(`mt`),marginRight:G(`mr`),marginBottom:G(`mb`),marginLeft:G(`ml`),width:G(`w`),height:G(`h`),minHeight:G(`min-h`),minWidth:G(`min-w`),flexBasis:G(`basis`),aspectRatio:e=>Be(W)(e)??Ie(`aspect`,e),gap:G(`gap`),rowGap:G(`gap-y`),columnGap:G(`gap-x`),justifyContent:Be(B),alignItems:Be(Se),flexWrap:Be(V),gridColumns:e=>{let t=/^grid-cols-(\d+)$/.exec(e);return t?t[1]:Ie(`grid-cols`,e)},borderWidth:e=>{if(e===`border`)return`1`;let t=/^border-(\d+(?:\.\d+)?)$/.exec(e);if(t)return t[1];let n=Ie(`border`,e);return n!==null&&!Le.test(n)?n:null},borderColor:ze(`border`),borderRadius:Re(`rounded`,`radius`),borderStyle:Be(Ce),lineHeight:Re(`leading`,`leading`),letterSpacing:Re(`tracking`,`tracking`),decoration:Be(_e),letterCase:Be(ve)},He=e=>{let t=e.replace(/\[[^\]]*\]/g,`[]`);return!t.includes(`:`)&&!t.includes(`/`)&&!e.startsWith(`[`)};function Ue(e,t,n=A()){let r=Ve[e];if(!r)return;let i;for(let e of t){if(!He(e))continue;let t=r(e,n);t!==null&&(i=t)}return i}function We(e,t,n,r=A()){let i=Ve[e],a=n.filter(e=>!i||!He(e)||i(e,r)===null),o=t?je[e]?.toClass(t,r):null;return o&&a.push(o),a}var Ge=[{prefix:`text`,namespaces:[`text`,`color`],skip:/^(left|center|right|justify|start|end|wrap|nowrap|balance|pretty|ellipsis|clip)$/},{prefix:`bg`,namespaces:[`color`],skip:/^(cover|contain|center|fixed|local|scroll|repeat|no-repeat|none|top|bottom|left|right|auto|clip-.*|origin-.*|gradient-.*|linear-.*|radial-.*|conic-.*)$/},{prefix:`border`,namespaces:[`color`],skip:/^(\d+(\.\d+)?)$|^(solid|dashed|dotted|double|hidden|none|collapse|separate|spacing.*)$|^[trblxyse](-|$)/},{prefix:`rounded`,namespaces:[`radius`],skip:/^(none|full|[trblxyse]{1,2}(-|$).*)$/},{prefix:`leading`,namespaces:[`leading`],skip:/^(none|\d+(\.\d+)?)$/},{prefix:`tracking`,namespaces:[`tracking`]}];function Ke(e,t=A()){let n=[];for(let r of e)if(He(r))for(let{prefix:e,namespaces:i,skip:a}of Ge){if(!r.startsWith(`${e}-`))continue;let o=r.slice(e.length+1);if(!o||o.startsWith(`[`)||a?.test(o))break;i.some(e=>N(t,`${e}-${o}`))||n.push({cls:r,suffix:o,namespaces:i});break}return n}var qe=[`content`,`structure`,`design`,`advanced`],Je=[`parent`,`block`,`inline`,`other`],Ye=[`toggle-group`,`toggle`,`select`,`text`,`number`,`media`],Xe=[`link`,`caption`,`replace`,`text-align`,`field-options`,`setting-options`,`transform-options`,`toggle-setting`,`add-child`,`copy`,`text`,`style-options`],Ze={link:[`field`,`setting`,`targetSetting`],caption:[`field`,`setting`],replace:[`field`],"text-align":[],"field-options":[`field`,`options`],"setting-options":[`setting`,`options`],"transform-options":[`options`],"toggle-setting":[`setting`],"add-child":[`type`],copy:[`field`],text:[`field`,`setting`],"style-options":[`style`,`options`]},Qe={"toggle-group":[`field`,`transform`,`setting`,`default`,`options`,`role`,`help`,`when`],toggle:[`setting`,`default`,`role`,`help`,`when`],select:[`setting`,`default`,`options`,`role`,`help`,`when`],text:[`setting`,`field`,`default`,`placeholder`,`role`,`help`,`when`],number:[`setting`,`default`,`min`,`max`,`step`,`role`,`help`,`when`],media:[`field`,`role`,`help`,`when`]},$e=/^[a-z][a-z0-9-]*$/,et=new Map;function K(e,t){throw Error(`PublrEditor: ${e}: ${t}`)}function tt(e,n){let r=`registerBlock("${e}")`;$e.test(e??``)||K(r,`type must be a lowercase name`),e===`raw-html`&&K(r,`"${t}" is the reserved passthrough type`),et.has(e)&&K(r,`already registered`),(typeof n!=`object`||!n)&&K(r,`definition must be an object`);for(let e of Object.keys(n))[`label`,`render`,`placeholder`,`category`,`description`,`icon`,`settings`,`toolbar`,`allowedChildren`,`childTemplate`,`internal`,`phantom`,`noSplit`,`allowedFormats`,`supports`,`variations`,`classTarget`].includes(e)||K(r,`unknown key "${e}"`);(typeof n.label!=`string`||!n.label)&&K(r,`label is required`),typeof n.render!=`function`&&K(r,`render(fields) function is required`),`placeholder`in n&&typeof n.placeholder!=`string`&&K(r,`placeholder must be a string`),`category`in n&&(typeof n.category!=`string`||!n.category)&&K(r,`category must be a non-empty string`),`description`in n&&(typeof n.description!=`string`||!n.description)&&K(r,`description must be a non-empty string`),`icon`in n&&(typeof n.icon!=`string`||!n.icon)&&K(r,`icon must be a non-empty string`),`internal`in n&&typeof n.internal!=`boolean`&&K(r,`internal must be a boolean`),`phantom`in n&&typeof n.phantom!=`boolean`&&K(r,`phantom must be a boolean`);let a=e=>{if(!(e in n))return;let t=n[e];return(!Array.isArray(t)||!t.length||t.some(e=>typeof e!=`string`||!e))&&K(r,`${e} must be a non-empty array of names`),Object.freeze([...t])},o=a(`allowedChildren`),c=a(`childTemplate`),l=a(`noSplit`),u;if(`allowedFormats`in n){Array.isArray(n.allowedFormats)||K(r,`allowedFormats must be an array`);for(let e of n.allowedFormats)(typeof e!=`string`||!S.includes(e))&&K(r,`allowedFormats: "${String(e)}" is not a known mark (${S.join(`, `)})`);u=Object.freeze([...n.allowedFormats])}let d={typography:[`fontSize`,`lineHeight`,`letterSpacing`,`decoration`,`letterCase`,`textAlign`,`fontWeight`,`fontStyle`],color:[`text`,`background`],spacing:[`padding`,`paddingTop`,`paddingRight`,`paddingBottom`,`paddingLeft`,`margin`,`marginTop`,`marginRight`,`marginBottom`,`marginLeft`],dimensions:[`width`,`height`,`minHeight`,`minWidth`,`flexBasis`,`aspectRatio`],layout:[`gap`,`rowGap`,`columnGap`,`justifyContent`,`alignItems`,`flexWrap`,`gridColumns`],border:[`width`,`color`,`radius`,`style`]},f;if(`supports`in n){let e=n.supports;(typeof e!=`object`||!e)&&K(r,`supports must be an object`);for(let t of Object.keys(e)){t in d||K(r,`supports: unknown panel "${t}"`);let n=e[t];(typeof n!=`object`||!n)&&K(r,`supports.${t} must be an object`);for(let[e,i]of Object.entries(n)){if(d[t].includes(e)||K(r,`supports.${t}: unknown key "${e}"`),typeof i==`boolean`)continue;(typeof i!=`object`||!i||Array.isArray(i))&&K(r,`supports.${t}.${e} must be a boolean or capability object`);for(let n of Object.keys(i))[`default`,`values`,`allowCustom`].includes(n)||K(r,`supports.${t}.${e}: unknown capability "${n}"`);let n=i;n.default!=null&&typeof n.default!=`boolean`&&K(r,`supports.${t}.${e}.default must be a boolean`),n.allowCustom!=null&&typeof n.allowCustom!=`boolean`&&K(r,`supports.${t}.${e}.allowCustom must be a boolean`),n.values!=null&&(!Array.isArray(n.values)||!n.values.length||n.values.some(e=>typeof e!=`string`||!e))&&K(r,`supports.${t}.${e}.values must be non-empty strings`)}}f=Object.freeze(Object.fromEntries(Object.entries(e).map(([e,t])=>[e,Object.freeze(Object.fromEntries(Object.entries(t).map(([e,t])=>[e,t&&typeof t==`object`?Object.freeze({...t,...Array.isArray(t.values)?{values:Object.freeze([...t.values??[]])}:{}}):t])))])))}let p;if(`variations`in n){(!Array.isArray(n.variations)||!n.variations.length)&&K(r,`variations must be a non-empty array`);let e=new Set;p=Object.freeze(n.variations.map((t,n)=>{let i=`variations[${n}]`;return(typeof t!=`object`||!t)&&K(r,`${i} must be an object`),(typeof t.name!=`string`||!$e.test(t.name))&&K(r,`${i}: name must be a lowercase name`),(typeof t.label!=`string`||!t.label)&&K(r,`${i}: label is required`),typeof t.class!=`string`&&K(r,`${i}: class must be a string`),e.has(t.name)&&K(r,`${i}: duplicate variation "${t.name}"`),e.add(t.name),Object.freeze({name:t.name,label:t.label,class:t.class})}))}if(o&&c)for(let e of c)o.includes(e)||K(r,`childTemplate type "${e}" is not in allowedChildren`);let m;`classTarget`in n&&((typeof n.classTarget!=`string`||!n.classTarget)&&K(r,`classTarget must be a non-empty selector string`),m=n.classTarget);let g=document.createElement(`div`);try{g.innerHTML=n.render({})}catch(e){K(r,`render({}) threw — render must tolerate absent fields (${String(e)})`)}let _=g.firstElementChild;(!_||g.children.length!==1)&&K(r,`render must produce exactly one root element`),_.getAttribute(`data-pb-block`)!==e&&K(r,`render root must carry data-pb-block="${e}"`),_.querySelector(`script[type="application/json"][data-pb-settings]`)&&K(r,`render must not emit a data-pb-settings island — downcast owns the island`);let y=[];for(let e of h(_))for(let{attr:t,kind:n}of i){let i=e.getAttribute(t);if(!i)continue;y.some(e=>e.name===i)&&K(r,`field "${i}" is carried twice in the render output`);let a=(n===`text`||n===`rich`)&&!!e.closest(`pre`),o=v(e,n);y.push(Object.freeze({name:i,type:n,default:typeof o==`object`?Object.freeze(o):o,...a?{preformatted:!0}:{}}))}if(l)for(let e of l)y.some(t=>t.name===e)||K(r,`noSplit field "${e}" is not carried by the render`);let b=[..._.querySelectorAll(`[${s}]`)];_.matches(`[data-pb-children]`)&&b.unshift(_);let x=b.filter(e=>e.closest(`[data-pb-block]`)===_);x.length>1&&K(r,`at most one ${s} slot per render`);let C=x[0];C&&((C.hasAttribute(`data-pb-text`)||C.hasAttribute(`data-pb-rich`))&&K(r,`the ${s} slot cannot also be a field carrier`),C.children.length&&K(r,`the ${s} slot must be empty in the probe render`)),(o||c)&&!C&&K(r,`allowedChildren/childTemplate require a children slot in the render`),n.phantom&&!C&&K(r,`phantom requires a children slot — a transparent wrapper exists FOR its children`);let w;if(`settings`in n){Array.isArray(n.settings)||K(r,`settings must be an array`);let e=new Set;w=Object.freeze(n.settings.map((t,n)=>{let i=`settings[${n}]`;(typeof t!=`object`||!t)&&K(r,`${i} must be an object`);let a=t.control;Ye.includes(a)||K(r,`${i}: unknown control "${String(a)}"`);for(let e of Object.keys(t))e!==`control`&&e!==`label`&&!Qe[a].includes(e)&&K(r,`${i}: unknown key "${e}" on a "${a}" control`);if((typeof t.label!=`string`||!t.label)&&K(r,`${i}: label is required`),t.role!=null&&!qe.includes(t.role)&&K(r,`${i}: unknown role "${String(t.role)}"`),t.help!=null&&(typeof t.help!=`string`||!t.help)&&K(r,`${i}: help must be a non-empty string`),t.when!=null){(typeof t.when!=`object`||Array.isArray(t.when))&&K(r,`${i}: when must be an object`);for(let e of Object.keys(t.when))[`field`,`setting`,`equals`,`notEquals`].includes(e)||K(r,`${i}.when: unknown key "${e}"`);Number(t.when.field!=null)+Number(t.when.setting!=null)!==1&&K(r,`${i}.when requires exactly one field or setting`),Number(`equals`in t.when)+Number(`notEquals`in t.when)!==1&&K(r,`${i}.when requires exactly one equals or notEquals value`)}let o=t.field!=null,s=t.transform!=null,c=t.setting!=null;if(Number(o)+Number(s)+Number(c)!==1&&K(r,`${i}: exactly one of "field", "transform" or "setting" is required`),o){let e=y.find(e=>e.name===t.field);e||K(r,`${i}: field "${String(t.field)}" is not carried by the render`),a===`text`&&e.type===`image`&&K(r,`${i}: a "text" control cannot bind an image field`),a===`media`&&e.type!==`image`&&K(r,`${i}: a "media" control requires an image-kinded field`)}s&&t.transform!==!0&&K(r,`${i}: transform must be true`),c&&((typeof t.setting!=`string`||!t.setting)&&K(r,`${i}: setting must be a non-empty string`),e.has(t.setting)&&K(r,`${i}: duplicate setting "${t.setting}"`),e.add(t.setting),`default`in t||K(r,`${i}: island-bound settings require a default`));let l;if(a===`toggle-group`||a===`select`){(!Array.isArray(t.options)||!t.options.length)&&K(r,`${i}: options must be a non-empty array`);let e=new Set;l=Object.freeze(t.options.map(t=>((typeof t!=`object`||!t||typeof t.value!=`string`||!t.value)&&K(r,`${i}: every option needs a non-empty string value`),(typeof t.label!=`string`||!t.label)&&K(r,`${i}: every option needs a non-empty string label`),`icon`in t&&(typeof t.icon!=`string`||!t.icon)&&K(r,`${i}: option icon must be a non-empty string`),e.has(t.value)&&K(r,`${i}: duplicate option value "${t.value}"`),e.add(t.value),Object.freeze({value:t.value,label:t.label,...t.icon==null?{}:{icon:t.icon}}))))}if(c){let e=t.default;if(a===`toggle`&&typeof e!=`boolean`&&K(r,`${i}: a "toggle" default must be a boolean`),a===`text`&&typeof e!=`string`&&K(r,`${i}: a "text" default must be a string`),(a===`toggle-group`||a===`select`)&&(typeof e!=`string`||!l.some(t=>t.value===e))&&K(r,`${i}: the default must be one of the option values`),a===`number`){(typeof e!=`number`||!Number.isFinite(e))&&K(r,`${i}: a "number" default must be a finite number`);for(let e of[`min`,`max`,`step`])e in t&&(typeof t[e]!=`number`||!Number.isFinite(t[e]))&&K(r,`${i}: ${e} must be a finite number`);t.step!=null&&t.step<=0&&K(r,`${i}: step must be > 0`),t.min!=null&&t.max!=null&&t.min>t.max&&K(r,`${i}: min must be ≤ max`),(t.min!=null&&e<t.min||t.max!=null&&e>t.max)&&K(r,`${i}: the default must sit within [min, max]`)}}return a===`text`&&`placeholder`in t&&typeof t.placeholder!=`string`&&K(r,`${i}: placeholder must be a string`),Object.freeze({control:a,label:t.label,...o?{field:t.field}:{},...s?{transform:!0}:{},...c?{setting:t.setting,default:t.default}:{},...l?{options:l}:{},...a===`text`&&t.placeholder!=null?{placeholder:t.placeholder}:{},...a===`number`&&t.min!=null?{min:t.min}:{},...a===`number`&&t.max!=null?{max:t.max}:{},...a===`number`&&t.step!=null?{step:t.step}:{},...t.role==null?{}:{role:t.role},...t.help==null?{}:{help:t.help},...t.when==null?{}:{when:Object.freeze({...t.when.field==null?{}:{field:t.when.field},...t.when.setting==null?{}:{setting:t.when.setting},...`equals`in t.when?{equals:t.when.equals}:{},...`notEquals`in t.when?{notEquals:t.when.notEquals}:{}})}})}));for(let[e,t]of w.entries())t.when&&(t.when.field&&!y.some(e=>e.name===t.when.field)&&K(r,`settings[${e}].when: field "${t.when.field}" is not carried by the render`),t.when.setting&&!w.some(e=>e.setting===t.when.setting)&&K(r,`settings[${e}].when: setting "${t.when.setting}" is not declared`))}let ee=Object.freeze((w??[]).filter(e=>e.setting!=null).map(e=>Object.freeze({name:e.setting,default:e.default}))),T;if(`toolbar`in n){Array.isArray(n.toolbar)||K(r,`toolbar must be an array`);let e=e=>ee.find(t=>t.name===e),t=e=>w?.find(t=>t.setting===e)?.role??`advanced`;T=Object.freeze(n.toolbar.map((n,i)=>{let a=`toolbar[${i}]`;(typeof n!=`object`||!n)&&K(r,`${a} must be an object`);let s=n.control;Xe.includes(s)||K(r,`${a}: unknown control "${String(s)}"`);for(let e of Object.keys(n))e!==`control`&&e!==`label`&&e!==`icon`&&e!==`group`&&e!==`role`&&!Ze[s].includes(e)&&K(r,`${a}: unknown key "${e}" on a "${s}" control`);if((typeof n.label!=`string`||!n.label)&&K(r,`${a}: label is required`),n.icon!=null&&(typeof n.icon!=`string`||!n.icon)&&K(r,`${a}: icon must be a non-empty string`),n.group!=null&&!Je.includes(n.group)&&K(r,`${a}: unknown group "${String(n.group)}"`),n.role!=null&&!qe.includes(n.role)&&K(r,`${a}: unknown role "${String(n.role)}"`),s===`replace`||s===`caption`){let e=y.find(e=>e.name===n.field);e||K(r,`${a}: field "${String(n.field)}" is not carried by the render`);let t=s===`replace`?`image`:`rich`;e.type!==t&&K(r,`${a}: a "${s}" control requires a ${t}-kinded field`)}if(s===`caption`){let t=e(n.setting);t||K(r,`${a}: setting "${String(n.setting)}" is not a declared island setting`),s===`caption`&&typeof t.default!=`boolean`&&K(r,`${a}: a "caption" setting must be a boolean (visibility) setting`)}if(s===`link`)if(Number(n.field!=null)+Number(n.setting!=null)!==1&&K(r,`${a}: a "link" control requires exactly one field or setting`),n.field!=null){let e=y.find(e=>e.name===n.field);(!e||e.type!==`link`)&&K(r,`${a}: a field-bound "link" control requires a link-kinded field`)}else e(n.setting)||K(r,`${a}: setting "${String(n.setting)}" is not a declared island setting`);if(s===`link`&&n.targetSetting!=null&&!e(n.targetSetting)&&K(r,`${a}: targetSetting "${String(n.targetSetting)}" is not a declared island setting`),s===`copy`){let e=y.find(e=>e.name===n.field);(!e||e.type!==`link`)&&K(r,`${a}: a "copy" control requires a link-kinded field`)}if(s===`text`)if(Number(n.field!=null)+Number(n.setting!=null)!==1&&K(r,`${a}: a "text" control requires exactly one field or setting`),n.field!=null){let e=y.find(e=>e.name===n.field);(!e||e.type!==`text`&&e.type!==`link`)&&K(r,`${a}: a field-bound "text" control requires a text or link field`)}else{let t=e(n.setting);(!t||typeof t.default!=`string`)&&K(r,`${a}: a setting-bound "text" control requires a string setting`)}let c;if(s===`field-options`||s===`setting-options`||s===`transform-options`||s===`style-options`){(!Array.isArray(n.options)||!n.options.length)&&K(r,`${a}: options must be a non-empty array`);let e=new Set;c=Object.freeze(n.options.map(t=>((typeof t!=`object`||!t||typeof t.value!=`string`||!t.value)&&K(r,`${a}: every option needs a non-empty string value`),(typeof t.label!=`string`||!t.label)&&K(r,`${a}: every option needs a non-empty string label`),t.icon!=null&&(typeof t.icon!=`string`||!t.icon)&&K(r,`${a}: option icon must be a non-empty string`),e.has(t.value)&&K(r,`${a}: duplicate option value "${t.value}"`),e.add(t.value),Object.freeze({value:t.value,label:t.label,...t.icon==null?{}:{icon:t.icon}}))))}let l=n.field==null?void 0:y.find(e=>e.name===n.field),u=n.setting==null?void 0:e(n.setting);s===`field-options`&&!l&&K(r,`${a}: field "${String(n.field)}" is not carried by the render`),(s===`setting-options`||s===`toggle-setting`)&&!u&&K(r,`${a}: setting "${String(n.setting)}" is not a declared island setting`),s===`toggle-setting`&&typeof u.default!=`boolean`&&K(r,`${a}: a "toggle-setting" control requires a boolean setting`),s===`add-child`&&(C||K(r,`${a}: an "add-child" control requires a child slot`),(typeof n.type!=`string`||!$e.test(n.type))&&K(r,`${a}: an "add-child" control requires a block type`),o&&!o.includes(n.type)&&K(r,`${a}: child type "${n.type}" is not allowed by this block`)),s===`style-options`&&(typeof n.style!=`string`||!Fe(f,n.style))&&K(r,`${a}: style "${String(n.style)}" is not supported by this block`);let d=s===`text-align`||s===`style-options`?`design`:s===`transform-options`||s===`add-child`?`structure`:s===`field-options`?l?.type===`tag`?`structure`:`content`:s===`setting-options`||s===`toggle-setting`?t(n.setting):`content`;return Object.freeze({control:s,label:n.label,...n.icon==null?{}:{icon:n.icon},...n.field==null?{}:{field:n.field},...n.setting==null?{}:{setting:n.setting},...n.targetSetting==null?{}:{targetSetting:n.targetSetting},...n.type==null?{}:{type:n.type},...n.style==null?{}:{style:n.style},...c?{options:c}:{},group:n.group??(s===`replace`?`other`:`block`),role:n.role??d})}))}let E=Object.freeze({label:n.label,render:n.render,...n.placeholder==null?{}:{placeholder:n.placeholder},...n.category==null?{}:{category:n.category},...n.description==null?{}:{description:n.description},...n.icon==null?{}:{icon:n.icon},...w?{settings:w}:{},...T?{toolbar:T}:{},...o?{allowedChildren:o}:{},...c?{childTemplate:c}:{},...n.internal?{internal:!0}:{},...n.phantom?{phantom:!0}:{},...l?{noSplit:l}:{},...u===void 0?{}:{allowedFormats:u},...f?{supports:f}:{},...p?{variations:p}:{},...m?{classTarget:m}:{},fields:Object.freeze(y),islandSettings:ee,acceptsChildren:!!C});return et.set(e,E),E}function nt(e){return et.delete(e)}var q=e=>et.get(e);function rt(){return Array.from(et,([e,t])=>({type:e,...t}))}function it(e,t){if(!e.islandSettings.length)return;let n={};for(let t of e.islandSettings)n[t.name]=t.default;return Object.assign(n,t)}function at(e,t){if(!t.islandSettings.length)return;let n;try{n=JSON.parse(_(e)?.textContent??`{}`)}catch{n=void 0}let r={};if(typeof n==`object`&&n)for(let e of t.islandSettings){let t=n[e.name];t!==void 0&&JSON.stringify(t)!==JSON.stringify(e.default)&&(r[e.name]=t)}return r}function ot(e,t){return!t.classTarget||e.matches(t.classTarget)?e:e.querySelector(t.classTarget)??e}function st(e,t,n){let r=document.createElement(`div`);try{r.innerHTML=e.render(t,n)}catch{return[]}let i=r.firstElementChild;return i?y(ot(i,e).getAttribute(`class`)):[]}function ct(e,t,n){if(t===`image`||t===`link`)return e;if(t!==`rich`)return e.replace(/\s+/g,` `).trim();e=e;let r=n.cloneNode(!1);r.innerHTML=e;let i=document.createTreeWalker(r,NodeFilter.SHOW_TEXT);for(let e;e=i.nextNode();)e.data=e.data.replace(/\s+/g,` `);return r.innerHTML.trim()}function lt(e){let n=e.getAttribute(`data-pb-block`),r=n?q(n):null;if(!n||!r){let n=e.cloneNode(!0);return n.removeAttribute(`data-pb-id`),{type:t,id:e.getAttribute(`data-pb-id`)||m(),fields:{html:n.outerHTML}}}let a={type:n,id:e.getAttribute(`data-pb-id`)||m(),fields:{}},o=e.getAttribute(c);o&&(a.pattern=o);for(let t of h(e))for(let{attr:e,kind:n}of i){let i=t.getAttribute(e);if(!i)continue;let o=v(t,n);a.fields[i]=r.fields.find(e=>e.name===i)?.preformatted?o:ct(o,n,t)}for(let e of r.fields)e.name in a.fields||(a.fields[e.name]=e.default);let s=at(e,r);s&&(a.settings=s);let l=e.getAttribute(`style`)?.trim();if(l&&(a.css=l),r.acceptsChildren){let t=g(e);a.children=t?[...t.children].filter(e=>!e.matches(`script[type="application/json"][data-pb-settings]`)&&!e.matches(`script[type="application/json"][data-pb-style]`)).map(lt):[]}let u=new Set(st(r,a.fields,it(r,a.settings)));return a.classes=y(ot(e,r).getAttribute(`class`)).filter(e=>!u.has(e)).join(` `),a}function ut(e){return{blocks:[...e.children].map(lt)}}function dt(e){let t=document.createElement(`div`);if(e.type===`raw-html`){t.innerHTML=r(e.fields?.html);let n=t.firstElementChild;return n&&n.setAttribute(`data-pb-id`,e.id),n}let n=q(e.type);if(!n)return console.warn(`PublrEditor: no registered block for "${e.type}" — dropped`),null;t.innerHTML=n.render(e.fields??{},it(n,e.settings));let i=t.firstElementChild;if(!i)return null;if(i.getAttribute(`data-pb-block`)!==e.type&&console.warn(`PublrEditor: render for "${e.type}" did not emit data-pb-block="${e.type}"`),i.setAttribute(`data-pb-id`,e.id),e.pattern&&i.setAttribute(c,e.pattern),e.settings&&Object.keys(e.settings).length){let t=document.createElement(`script`);t.setAttribute(`type`,`application/json`),t.setAttribute(`data-pb-settings`,``),t.textContent=d(JSON.stringify(e.settings)),i.prepend(t)}let a=y(e.classes);if(a.length){let e=ot(i,n),t=[...y(e.getAttribute(`class`))];for(let e of a)t.includes(e)||t.push(e);e.setAttribute(`class`,t.join(` `))}if(e.css&&i.setAttribute(`style`,e.css),e.children){let t=g(i);if(t)for(let n of e.children){let e=dt(n);e&&t.appendChild(e)}else e.children.length&&console.warn(`PublrEditor: render for "${e.type}" emitted no data-pb-children slot — ${e.children.length} inner block(s) dropped`)}return i}function ft(e){for(let t of e.querySelectorAll(`script[type="application/json"][data-pb-settings], script[type="application/json"][data-pb-style]`))t.remove();for(let t of[e,...e.querySelectorAll(`*`)])for(let e of t.getAttributeNames())e.startsWith(`data-pb-`)&&t.removeAttribute(e)}var pt=e=>{let t=e.getAttribute(`data-pb-block`);return!!t&&!!q(t)?.phantom};function mt(e){for(let t of[...e.querySelectorAll(`[data-pb-block]`)].reverse())pt(t)&&t.replaceWith(...t.childNodes)}function ht(e,t=`editor`){return e.blocks.flatMap(e=>{let n=dt(e);if(!n)return[];if(t!==`data`)return[n.outerHTML];let r=pt(n);return mt(n),ft(n),r?[...n.children].map(e=>e.outerHTML):[n.outerHTML]}).filter(Boolean).join(`
`)}function gt(e,t,n=null){for(let r=0;r<e.length;r++){let i=e[r];if(i.id===t)return{block:i,list:e,index:r,parent:n};if(i.children){let e=gt(i.children,t,i);if(e)return e}}return null}function _t(e){let t=[],n=e=>{for(let r of e)t.push(r),r.children&&n(r.children)};return n(e),t}function vt(e,t){for(let n of e){if(n.id===t)return[n];if(n.children){let e=vt(n.children,t);if(e)return[n,...e]}}return null}function yt(e,t,n){let r=vt(e,t),i=vt(e,n);if(!r||!i)return null;let a=0;for(;a<r.length&&a<i.length&&r[a]===i[a];)a++;if(a===r.length&&a===i.length)return null;if(a===r.length||a===i.length){let t=r[a-1],n=a===1?e:r[a-2].children,i=n.indexOf(t);return i<0?null:{list:n,lo:i,hi:i}}let o=a===0?e:r[a-1].children,s=o.indexOf(r[a]),c=o.indexOf(i[a]);return s<0||c<0?null:s<c?{list:o,lo:s,hi:c}:{list:o,lo:c,hi:s}}var bt=`pattern`,xt=/^[a-z][a-z0-9-]*$/,St=/^\d+\.\d+$/,Ct=new Map,wt=new Map;function Tt(e,t){throw Error(`PublrEditor: ${e}: ${t}`)}function Et(e,t){let n=`registerPattern("${e}")`;xt.test(e??``)||Tt(n,`name must be a lowercase name`),Ct.has(e)&&Tt(n,`already registered`),(typeof t!=`object`||!t)&&Tt(n,`definition must be an object`);for(let e of Object.keys(t))[`label`,`content`,`version`,`category`,`description`,`icon`].includes(e)||Tt(n,`unknown key "${e}"`);(typeof t.label!=`string`||!t.label)&&Tt(n,`label is required`),(typeof t.content!=`string`||!t.content.trim())&&Tt(n,`content (annotated-HTML fragment) is required`),`version`in t&&(typeof t.version!=`string`||!St.test(t.version))&&Tt(n,`version must be "major.minor" (e.g. "1.0")`),`category`in t&&(typeof t.category!=`string`||!t.category)&&Tt(n,`category must be a non-empty string`),`description`in t&&(typeof t.description!=`string`||!t.description)&&Tt(n,`description must be a non-empty string`),`icon`in t&&(typeof t.icon!=`string`||!t.icon)&&Tt(n,`icon must be a non-empty string`);let i=document.createElement(`div`);i.innerHTML=t.content,i.children.length||Tt(n,`content must contain at least one block element`);let a=ut(i).blocks,o=_t(a);for(let e of o){if(e.type===`raw-html`){let t=document.createElement(`div`);t.innerHTML=r(e.fields.html),t.firstElementChild?.hasAttribute(`data-pb-block`)&&Tt(n,`content references an unregistered block type — register the blocks before the pattern`);continue}let t=new Set(q(e.type).fields.map(e=>e.name));for(let r of Object.keys(e.fields))t.has(r)||Tt(n,`"${e.type}" does not carry a field "${r}" — the fragment would drop it`)}o.length<2&&Tt(n,`content must expand to at least two blocks — one block is a block, not a pattern`);let s=Object.freeze({label:t.label,content:t.content,version:t.version??`1.0`,...t.category==null?{}:{category:t.category},...t.description==null?{}:{description:t.description},...t.icon==null?{}:{icon:t.icon}});return Ct.set(e,s),s}function Dt(e){return wt.delete(e),Ct.delete(e)}var Ot=e=>Ct.get(e);function kt(){return Array.from(Ct,([e,t])=>({name:e,...t}))}function At(e,t){let n=Ct.get(e);n||Tt(`publishPattern("${e}")`,`not registered`);let r=Ft(n.content,t);if(r===`none`)return{version:n.version,kind:r};let i=Nt(n.version,r),a={label:n.label,...n.category==null?{}:{category:n.category},...n.description==null?{}:{description:n.description},...n.icon==null?{}:{icon:n.icon}},o=wt.get(e);Ct.delete(e);try{Et(e,{...a,version:i,content:t})}catch(t){throw Ct.set(e,n),t}let s=o??new Map;return s.set(n.version,n.content),wt.set(e,s),{version:i,kind:r}}function jt(e,t){let n=Ct.get(e);return n?.version===t?n.content:wt.get(e)?.get(t)}function Mt(e,t){let n=e=>St.test(e)?e.split(`.`).map(Number):[1,0],[r,i]=n(e),[a,o]=n(t);return r-a||i-o}function Nt(e,t){let[n,r]=St.test(e)?e.split(`.`).map(Number):[1,0];return t===`major`?`${n+1}.0`:`${n}.${r+1}`}function Pt(e,t){let n=e=>JSON.stringify({f:e.fields,c:e.classes??``,s:e.settings??{}}),r=[],i=[],a=0;for(let o=0;o<e.length;o++){let s=n=>n>=a&&t[n].type===e[o].type,c=t.findIndex((t,r)=>s(r)&&n(t)===n(e[o])),l=c===-1?t.findIndex((e,t)=>s(t)):c;l===-1?i.push(o):(r.push([o,l]),a=l+1)}let o=new Set(r.map(([,e])=>e));return{pairs:r,removed:i,added:t.map((e,t)=>t).filter(e=>!o.has(e))}}function Ft(e,t){let n=e=>{let t=document.createElement(`div`);return t.innerHTML=e,ut(t).blocks};return It(n(e),n(t))}function It(e,t){let{pairs:n,removed:r,added:i}=Pt(e,t);if(r.length)return`major`;let a=i.length?`minor`:`none`,o=e=>JSON.stringify({f:e.fields,c:e.classes??``,s:e.settings??{}});for(let[r,i]of n){o(e[r])!==o(t[i])&&(a=`minor`);let n=It(e[r].children??[],t[i].children??[]);if(n===`major`)return`major`;n===`minor`&&(a=`minor`)}return a}var Lt=e=>e.type!==`raw-html`&&!!q(e.type)?.fields.some(e=>e.type!==`tag`);function Rt(e){let t=[],n=e=>{for(let r of e)Lt(r)?t.push(r):r.children&&n(r.children)};return n(e.children??[]),t}var zt={typography:{fontSize:!0,lineHeight:!0,letterSpacing:!0,decoration:!0,letterCase:!0,textAlign:!0,fontWeight:{default:!1},fontStyle:{default:!1}},color:{text:!0,background:!0},spacing:{padding:!0,paddingTop:{default:!1},paddingRight:{default:!1},paddingBottom:{default:!1},paddingLeft:{default:!1},margin:!0,marginTop:{default:!1},marginRight:{default:!1},marginBottom:{default:!1},marginLeft:{default:!1}},dimensions:{width:{default:!1},minHeight:{default:!1}},border:{width:!0,color:!0,radius:!0,style:{default:!1}}},Bt={color:{text:!0,background:!0},spacing:{padding:!0,paddingTop:{default:!1},paddingRight:{default:!1},paddingBottom:{default:!1},paddingLeft:{default:!1},margin:!0,marginTop:{default:!1},marginRight:{default:!1},marginBottom:{default:!1},marginLeft:{default:!1}},dimensions:{width:{default:!1},height:{default:!1},minHeight:{default:!1},minWidth:{default:!1}},layout:{gap:!0,justifyContent:!0,alignItems:!0},border:{width:!0,color:!0,radius:!0,style:{default:!1}}},Vt={spacing:{padding:!0,margin:!0},dimensions:{width:{default:!1},height:{default:!1},aspectRatio:{default:!1,values:[`auto`,`square`,`video`]}},border:{width:!0,color:!0,radius:!0,style:{default:!1}}},Ht=[`h1`,`h2`,`h3`,`h4`,`h5`,`h6`],Ut=`heading`,Wt={label:`Heading`,category:`Text`,icon:`heading`,placeholder:`Heading`,supports:zt,description:`Introduce new sections and organize content to help visitors (and search engines) understand the structure of your content.`,toolbar:[{control:`field-options`,label:`Change heading level`,field:`level`,options:Ht.map((e,t)=>({value:e,label:e.toUpperCase(),icon:`heading-level-${t+1}`}))},{control:`text-align`,label:`Align text`}],settings:[{control:`toggle-group`,label:`Level`,field:`level`,role:`structure`,options:Ht.map((e,t)=>({value:e,label:e.toUpperCase(),icon:`heading-level-${t+1}`}))}],render(e){let t=typeof e.level==`string`?e.level:``,n=Ht.includes(t)?t:`h2`;return`<${n} data-pb-block="heading" data-pb-tag="level" data-pb-rich="text">${r(e.text)}</${n}>`}},Gt=`paragraph`,Kt={label:`Paragraph`,category:`Text`,icon:`paragraph`,description:`Start with the basic building block of all narrative.`,supports:zt,variations:[{name:`display`,label:`Display`,class:`text-3xl font-bold leading-tight`},{name:`subtitle`,label:`Subtitle`,class:`text-lg text-neutral-500`},{name:`annotation`,label:`Annotation`,class:`text-sm text-neutral-500 italic`}],toolbar:[{control:`text-align`,label:`Align text`}],settings:[{control:`toggle`,label:`Drop cap`,setting:`dropCap`,default:!1,role:`design`},{control:`toggle-group`,label:`Text direction`,setting:`direction`,default:`auto`,role:`advanced`,options:[{value:`auto`,label:`Auto`},{value:`ltr`,label:`LTR`},{value:`rtl`,label:`RTL`}]}],render(e,t){return`<p data-pb-block="paragraph" data-pb-rich="body"${t?.direction===`ltr`||t?.direction===`rtl`?` dir="${t.direction}"`:``}${t?.dropCap===!0?` class="first-letter:float-left first-letter:pr-2 first-letter:text-[3.4em] first-letter:leading-[0.85] first-letter:font-bold"`:``}>${r(e.body)}</p>`}},qt=[`1`,`a`,`A`,`i`,`I`],Jt={1:`list-decimal`,a:`list-[lower-alpha]`,A:`list-[upper-alpha]`,i:`list-[lower-roman]`,I:`list-[upper-roman]`},Yt=`list`,Xt={label:`List`,category:`Text`,icon:`list`,description:`An organized collection of items displayed in a specific order.`,supports:zt,allowedChildren:[`list-item`],childTemplate:[`list-item`],toolbar:[{control:`field-options`,label:`List style`,field:`tag`,options:[{value:`ul`,label:`Unordered`,icon:`list-unordered`},{value:`ol`,label:`Ordered`,icon:`list-ordered`}]},{control:`add-child`,label:`Add list item`,type:`list-item`}],settings:[{control:`toggle-group`,label:`List style`,field:`tag`,role:`structure`,options:[{value:`ul`,label:`Unordered`,icon:`list-unordered`},{value:`ol`,label:`Ordered`,icon:`list-ordered`}]},{control:`toggle`,label:`Reverse order`,setting:`reversed`,default:!1,role:`structure`,when:{field:`tag`,equals:`ol`},help:`Display ordered items in descending order.`},{control:`number`,label:`Start value`,setting:`start`,default:1,step:1,role:`structure`,when:{field:`tag`,equals:`ol`},help:`Set the first number used by the ordered list.`},{control:`select`,label:`Numbering style`,setting:`type`,default:`1`,role:`structure`,when:{field:`tag`,equals:`ol`},options:[{value:`1`,label:`Numbers (1 2 3)`},{value:`a`,label:`Lowercase letters (a b c)`},{value:`A`,label:`Uppercase letters (A B C)`},{value:`i`,label:`Lowercase Roman (i ii iii)`},{value:`I`,label:`Uppercase Roman (I II III)`}]}],render(e,t){let n=e.tag===`ol`?`ol`:`ul`,r=``,i=`list-disc`;if(n===`ol`){let e=qt.includes(t?.type)?String(t.type):`1`;i=Jt[e],t?.reversed===!0&&(r+=` reversed`);let n=Number(t?.start);Number.isFinite(n)&&n!==1&&(r+=` start="${Math.trunc(n)}"`),e!==`1`&&(r+=` type="${e}"`)}return`<${n} data-pb-block="list" data-pb-tag="tag" data-pb-children class="${i} pl-6"${r}></${n}>`}},Zt=`list-item`,Qt={label:`List item`,category:`Text`,icon:`list-item`,internal:!0,supports:zt,placeholder:`List item…`,render(e){return`<li data-pb-block="list-item" data-pb-rich="content">${r(e.content)}</li>`}},$t=`quote`,en={label:`Quote`,category:`Text`,icon:`quote`,placeholder:`Quote`,description:`Give quoted text visual emphasis.`,supports:zt,toolbar:[{control:`text-align`,label:`Align text`},{control:`toggle-setting`,label:`Citation`,setting:`showCitation`,role:`content`}],variations:[{name:`plain`,label:`Plain`,class:`border-l-0 pl-0`}],settings:[{control:`toggle`,label:`Citation`,setting:`showCitation`,default:!1,role:`content`}],render(e,t){let n=r(e.citation),i=t===void 0||t.showCitation===!0||n.trim()!==``?`<cite data-pb-rich="citation" class="mt-1 block text-sm not-italic">${n}</cite>`:``;return`<blockquote data-pb-block="quote" class="border-l-2 pl-4"><div data-pb-rich="body">${r(e.body)}</div>${i}</blockquote>`}},tn=`pullquote`,nn={label:`Pullquote`,category:`Text`,icon:`pullquote`,placeholder:`Add quote…`,description:`Give special visual emphasis to a quote from your text.`,supports:zt,toolbar:[{control:`text-align`,label:`Align text`},{control:`toggle-setting`,label:`Citation`,setting:`showCitation`,role:`content`}],settings:[{control:`toggle`,label:`Citation`,setting:`showCitation`,default:!1,role:`content`}],render(e,t){let n=r(e.citation),i=t===void 0||t.showCitation===!0||n.trim()!==``?`<cite data-pb-rich="citation" class="mt-2 block text-sm not-italic">${n}</cite>`:``;return`<figure data-pb-block="pullquote" class="border-y py-6 text-center"><blockquote class="text-2xl"><div data-pb-rich="value">${r(e.value)}</div></blockquote>${i}</figure>`}},rn=`code`,an={label:`Code`,category:`Text`,icon:`code`,placeholder:`Write code…`,supports:zt,toolbar:[],render(e){return`<pre data-pb-block="code" data-pb-text="code">${f(e.code??``)}</pre>`}},on=`preformatted`,sn={label:`Preformatted`,category:`Text`,icon:`preformatted`,placeholder:`Preformatted text…`,description:`Add text that respects your spacing and tabs, and also allows styling.`,supports:zt,toolbar:[{control:`text-align`,label:`Align text`}],render(e){return`<pre data-pb-block="preformatted" data-pb-rich="content" class="whitespace-pre-wrap">${r(e.content)}</pre>`}},cn=`verse`,ln={label:`Verse`,category:`Text`,icon:`verse`,placeholder:`Write poetry…`,description:`Insert poetry. Use special spacing formats. Or quote song lyrics.`,supports:zt,toolbar:[{control:`text-align`,label:`Align text`}],render(e){return`<pre data-pb-block="verse" data-pb-rich="content" class="whitespace-pre-wrap [font-family:inherit] [font-size:inherit]">${r(e.content)}</pre>`}},un=`<tr><td></td><td></td></tr><tr><td></td><td></td></tr>`,dn=`table`,fn={label:`Table`,category:`Text`,icon:`table`,placeholder:`Add caption`,description:`Create structured content in rows and columns to display information.`,supports:zt,noSplit:[`head`,`body`,`foot`],toolbar:[{control:`caption`,label:`Caption`,field:`caption`,setting:`showCaption`},{control:`toggle-setting`,label:`Header section`,setting:`showHeader`,role:`structure`},{control:`toggle-setting`,label:`Footer section`,setting:`showFooter`,role:`structure`},{control:`toggle-setting`,label:`Fixed width cells`,setting:`fixedLayout`,role:`design`},{control:`setting-options`,label:`Align cells`,setting:`cellAlignment`,role:`design`,options:[{value:`left`,label:`Left`},{value:`center`,label:`Center`},{value:`right`,label:`Right`}]}],settings:[{control:`toggle`,label:`Caption`,setting:`showCaption`,default:!1,role:`content`},{control:`toggle`,label:`Header section`,setting:`showHeader`,default:!1,role:`structure`},{control:`toggle`,label:`Footer section`,setting:`showFooter`,default:!1,role:`structure`},{control:`toggle`,label:`Fixed width table cells`,setting:`fixedLayout`,default:!0,role:`design`},{control:`toggle-group`,label:`Cell text alignment`,setting:`cellAlignment`,default:`left`,role:`design`,options:[{value:`left`,label:`Left`},{value:`center`,label:`Center`},{value:`right`,label:`Right`}]}],render(e,t){let n=t?.fixedLayout===!1?``:` table-fixed`,i=t?.cellAlignment===`center`?` [&_:is(td,th)]:text-center`:t?.cellAlignment===`right`?` [&_:is(td,th)]:text-right`:` [&_:is(td,th)]:text-left`,a=r(e.caption),o=r(e.head),s=r(e.foot),c=t===void 0||t.showCaption===!0||a.trim()?`<caption data-pb-rich="caption" class="caption-bottom text-sm">${a}</caption>`:``,l=t===void 0||t.showHeader===!0||o.trim()?`<thead data-pb-rich="head" class="font-semibold">${o}</thead>`:``,u=t===void 0||t.showFooter===!0||s.trim()?`<tfoot data-pb-rich="foot">${s}</tfoot>`:``;return`<table data-pb-block="table" class="w-full border-collapse${n}${i} [&_:is(td,th)]:border [&_:is(td,th)]:p-2">${c}${l}<tbody data-pb-rich="body">${e.body===void 0?un:r(e.body)}</tbody>${u}</table>`}},pn=`details`,mn={label:`Details`,category:`Text`,icon:`details`,placeholder:`Write summary…`,description:`Hide and show additional content.`,supports:zt,toolbar:[{control:`toggle-setting`,label:`Open by default`,setting:`open`,role:`structure`}],settings:[{control:`toggle`,label:`Open by default`,setting:`open`,default:!1,role:`structure`},{control:`text`,label:`Accordion group name`,setting:`name`,default:``,placeholder:`group name`,role:`advanced`,help:`Details blocks with the same name behave as an exclusive accordion in supporting browsers.`}],render(e,t){let n=typeof t?.name==`string`&&t.name.trim()?` name="${p(t.name.trim())}"`:``;return`<details data-pb-block="details" class="rounded-sm border px-4 py-2"${t?.open===!0?` open`:``}${n}><summary data-pb-rich="summary" class="cursor-pointer font-semibold">${r(e.summary)}</summary><div data-pb-children class="mt-2"></div></details>`}},hn=`<mrow><msup><mi>x</mi><mn>2</mn></msup></mrow>`,gn=`math`,_n={label:`Math`,category:`Text`,icon:`math`,description:`Display mathematical notation (MathML).`,noSplit:[`math`],allowedFormats:[],toolbar:[],render(e){return`<math data-pb-block="math" data-pb-rich="math" display="block" class="block py-2 text-center">${e.math===void 0?hn:r(e.math)}</math>`}},vn={square:`[&_img]:aspect-square [&_img]:w-full`,"4-3":`[&_img]:aspect-[4/3] [&_img]:w-full`,"3-2":`[&_img]:aspect-[3/2] [&_img]:w-full`,"16-9":`[&_img]:aspect-video [&_img]:w-full`},yn=`image`,bn={label:`Image`,category:`Media`,icon:`image`,placeholder:`Add caption`,description:`Insert an image to make a visual statement.`,supports:Vt,classTarget:`img`,toolbar:[{control:`replace`,label:`Replace`,field:`image`,icon:`replace`},{control:`link`,label:`Link`,setting:`href`,targetSetting:`linkTarget`},{control:`caption`,label:`Caption`,field:`caption`,setting:`showCaption`},{control:`toggle-setting`,label:`Decorative`,setting:`isDecorative`,icon:`decorative`,role:`content`}],settings:[{control:`media`,label:`Image`,field:`image`,role:`content`},{control:`toggle`,label:`Decorative image`,setting:`isDecorative`,default:!1,role:`content`,help:`Mark the image as presentational so assistive technology skips it without discarding its saved description.`},{control:`text`,label:`Link URL`,setting:`href`,default:``,placeholder:`https://…`,role:`content`},{control:`toggle`,label:`Caption`,setting:`showCaption`,default:!1,role:`content`},{control:`select`,label:`Open in`,setting:`linkTarget`,default:`none`,role:`content`,when:{setting:`href`,notEquals:``},options:[{value:`none`,label:`Same tab`},{value:`_blank`,label:`New tab`}]},{control:`text`,label:`Link rel`,setting:`rel`,default:``,role:`advanced`,when:{setting:`href`,notEquals:``},help:`Space-separated relationship values such as nofollow or sponsored.`},{control:`text`,label:`Title attribute`,setting:`title`,default:``,role:`advanced`},{control:`select`,label:`Aspect ratio`,setting:`aspectRatio`,default:`auto`,role:`design`,options:[{value:`auto`,label:`Original`},{value:`square`,label:`Square (1:1)`},{value:`4-3`,label:`Standard (4:3)`},{value:`3-2`,label:`Classic (3:2)`},{value:`16-9`,label:`Wide (16:9)`}]},{control:`select`,label:`Scale`,setting:`scale`,default:`cover`,role:`design`,when:{setting:`aspectRatio`,notEquals:`auto`},help:`Choose how the image fits inside the selected aspect ratio.`,options:[{value:`cover`,label:`Cover`},{value:`contain`,label:`Contain`}]}],render(e,t){let n=e.image??{},i=(n.width?` width="${p(n.width)}"`:``)+(n.height?` height="${p(n.height)}"`:``),a=t?.isDecorative===!0?` role="presentation" aria-hidden="true"`:``,o=`<img data-pb-image="image" src="${p(n.src??``)}" alt="${p(n.alt??``)}"${i}${a} class="block max-w-full">`,s=typeof t?.href==`string`?t.href.trim():``,c=typeof t?.rel==`string`?t.rel.trim():``,l=[t?.linkTarget===`_blank`?`noopener`:``,c].filter(Boolean).join(` `),u=(t?.linkTarget===`_blank`?` target="_blank"`:``)+(l?` rel="${p(l)}"`:``)+(typeof t?.title==`string`&&t.title.trim()?` title="${p(t.title.trim())}"`:``),d=s?`<a href="${p(s)}"${u}>${o}</a>`:o,f=vn[String(t?.aspectRatio)]??``,m=f?t?.scale===`contain`?` [&_img]:object-contain`:` [&_img]:object-cover`:``,h=r(e.caption),g=t===void 0||t.showCaption===!0||h.trim()!==``?`<figcaption data-pb-rich="caption" class="mt-1.5 text-center text-sm text-neutral-500">${h}</figcaption>`:``;return`<figure data-pb-block="image"${f?` class="${f}${m}"`:``}>${d}${g}</figure>`}},xn=[`auto`,`metadata`,`none`],Sn=`video`,Cn={label:`Video`,category:`Media`,icon:`video`,placeholder:`Add caption`,description:`Embed a video from your media library or upload a new one.`,supports:Vt,toolbar:[{control:`replace`,label:`Replace`,field:`video`},{control:`caption`,label:`Caption`,field:`caption`,setting:`showCaption`}],settings:[{control:`media`,label:`Video`,field:`video`,role:`content`},{control:`toggle`,label:`Caption`,setting:`showCaption`,default:!1,role:`content`},{control:`toggle`,label:`Playback controls`,setting:`controls`,default:!0,help:`Show the browser's playback controls.`},{control:`toggle`,label:`Autoplay`,setting:`autoplay`,default:!1,help:`Browsers generally require autoplaying video to be muted.`},{control:`toggle`,label:`Loop`,setting:`loop`,default:!1},{control:`toggle`,label:`Muted`,setting:`muted`,default:!1},{control:`toggle`,label:`Play inline`,setting:`playsInline`,default:!1},{control:`select`,label:`Preload`,setting:`preload`,default:`metadata`,options:[{value:`auto`,label:`Auto`},{value:`metadata`,label:`Metadata`},{value:`none`,label:`None`}]},{control:`text`,label:`Poster image URL`,setting:`poster`,default:``,placeholder:`https://…/poster.jpg`,help:`Displayed before playback begins.`}],render(e,t){let n=e.video??{},i=(n.width?` width="${p(n.width)}"`:``)+(n.height?` height="${p(n.height)}"`:``),a=t?.controls===!1?``:` controls`,o=t?.autoplay===!0;o&&(a+=` autoplay`),t?.loop===!0&&(a+=` loop`),(t?.muted===!0||o)&&(a+=` muted`),(t?.playsInline===!0||o)&&(a+=` playsinline`);let s=String(t?.preload);xn.includes(s)&&s!==`metadata`&&(a+=` preload="${s}"`);let c=typeof t?.poster==`string`&&t.poster.trim()?` poster="${p(t.poster.trim())}"`:``,l=r(e.caption),u=t===void 0||t.showCaption===!0||l.trim()!==``?`<figcaption data-pb-rich="caption" class="mt-1.5 text-center text-sm text-neutral-500">${l}</figcaption>`:``;return`<figure data-pb-block="video"><video data-pb-image="video" src="${p(n.src??``)}" alt="${p(n.alt??``)}"${i}${a}${c} class="block w-full"></video>${u}</figure>`}},wn=[`auto`,`metadata`,`none`],Tn=`audio`,En={label:`Audio`,category:`Media`,icon:`audio`,placeholder:`Add caption`,description:`Embed a simple audio player.`,supports:Vt,toolbar:[{control:`replace`,label:`Replace`,field:`audio`},{control:`caption`,label:`Caption`,field:`caption`,setting:`showCaption`}],settings:[{control:`media`,label:`Audio`,field:`audio`,role:`content`},{control:`toggle`,label:`Caption`,setting:`showCaption`,default:!1,role:`content`},{control:`toggle`,label:`Autoplay`,setting:`autoplay`,default:!1},{control:`toggle`,label:`Loop`,setting:`loop`,default:!1},{control:`select`,label:`Preload`,setting:`preload`,default:`metadata`,options:[{value:`auto`,label:`Auto`},{value:`metadata`,label:`Metadata`},{value:`none`,label:`None`}]}],render(e,t){let n=e.audio??{},i=(n.width?` width="${p(n.width)}"`:``)+(n.height?` height="${p(n.height)}"`:``),a=` controls`;t?.autoplay===!0&&(a+=` autoplay`),t?.loop===!0&&(a+=` loop`);let o=String(t?.preload);wn.includes(o)&&o!==`metadata`&&(a+=` preload="${o}"`);let s=r(e.caption),c=t===void 0||t.showCaption===!0||s.trim()!==``?`<figcaption data-pb-rich="caption" class="mt-1.5 text-center text-sm text-neutral-500">${s}</figcaption>`:``;return`<figure data-pb-block="audio"><audio data-pb-image="audio" src="${p(n.src??``)}" alt="${p(n.alt??``)}"${i}${a} class="block w-full"></audio>${c}</figure>`}},Dn={0:`opacity-0`,10:`opacity-10`,20:`opacity-20`,30:`opacity-30`,40:`opacity-40`,50:`opacity-50`,60:`opacity-60`,70:`opacity-70`,80:`opacity-80`,90:`opacity-90`,100:`opacity-100`},On={"top-left":`justify-start items-start text-left`,"top-center":`justify-start items-center text-center`,"top-right":`justify-start items-end text-right`,"center-left":`justify-center items-start text-left`,"center-center":`justify-center items-center text-center`,"center-right":`justify-center items-end text-right`,"bottom-left":`justify-end items-start text-left`,"bottom-center":`justify-end items-center text-center`,"bottom-right":`justify-end items-end text-right`},kn=[`div`,`section`,`article`,`header`,`main`],An=`cover`,jn={label:`Cover`,category:`Media`,icon:`cover`,description:`Add an image with a text overlay.`,supports:{...Bt,dimensions:{...Bt.dimensions,minHeight:!0}},toolbar:[{control:`replace`,label:`Replace`,field:`image`},{control:`setting-options`,label:`Change content position`,setting:`contentPosition`,options:Object.keys(On).map(e=>({value:e,label:e.replace(`-`,` `)})),role:`design`},{control:`toggle-setting`,label:`Full height`,setting:`fullHeight`,role:`design`}],settings:[{control:`media`,label:`Background image`,field:`image`,role:`content`},{control:`number`,label:`Overlay opacity`,setting:`dimRatio`,default:50,min:0,max:100,step:10,role:`design`,help:`Control how strongly the overlay darkens the background image.`},{control:`toggle`,label:`Full viewport height`,setting:`fullHeight`,default:!1,role:`design`},{control:`toggle-group`,label:`Content position`,setting:`contentPosition`,default:`center-center`,role:`design`,options:Object.keys(On).map(e=>({value:e,label:e.replace(`-`,` `)}))},{control:`toggle`,label:`Fixed background (parallax)`,setting:`hasParallax`,default:!1,role:`design`},{control:`toggle-group`,label:`HTML element`,field:`tag`,role:`structure`,options:kn.map(e=>({value:e,label:e}))}],render(e,t){let n=e.image??{},r=(n.width?` width="${p(n.width)}"`:``)+(n.height?` height="${p(n.height)}"`:``),i=Dn[String(t?.dimRatio)]??`opacity-50`,a=On[String(t?.contentPosition)]??On[`center-center`],o=t?.hasParallax===!0,s=typeof e.tag==`string`&&kn.includes(e.tag)?e.tag:`div`;return`<${s} data-pb-block="cover" data-pb-tag="tag" class="pbe-cover relative isolate flex overflow-hidden p-4${t?.fullHeight===!0?` min-h-screen`:``}${o?` [clip-path:inset(0)]`:``}"><img data-pb-image="image" src="${p(n.src??``)}" alt="${p(n.alt??``)}"${r} class="${o?`fixed`:`absolute`} inset-0 -z-20 h-full w-full object-cover"><span class="absolute inset-0 -z-10 bg-black ${i}" aria-hidden="true"></span><div data-pb-children class="relative flex flex-1 flex-col gap-3 text-white ${a}"></div></${s}>`}},Mn={1:`grid-cols-1`,2:`grid-cols-2`,3:`grid-cols-3`,4:`grid-cols-4`,5:`grid-cols-5`,6:`grid-cols-6`,7:`grid-cols-7`,8:`grid-cols-8`},Nn={square:`[&_img]:aspect-square`,"4-3":`[&_img]:aspect-[4/3]`,"3-2":`[&_img]:aspect-[3/2]`,"16-9":`[&_img]:aspect-video`},Pn=`gallery`,Fn={label:`Gallery`,category:`Media`,icon:`gallery`,placeholder:`Add caption`,description:`Display multiple images in a rich gallery.`,supports:{spacing:{padding:!0,margin:!0},dimensions:{width:{default:!1}},layout:{gap:!0},border:{width:!0,color:!0,radius:!0,style:{default:!1}}},classTarget:`[data-pb-children]`,toolbar:[{control:`add-child`,label:`Add image`,type:`image`},{control:`caption`,label:`Caption`,field:`caption`,setting:`showCaption`},{control:`setting-options`,label:`Change image aspect ratio`,setting:`aspectRatio`,role:`design`,options:[{value:`square`,label:`Square`},{value:`4-3`,label:`4:3`},{value:`3-2`,label:`3:2`},{value:`16-9`,label:`16:9`}]}],allowedChildren:[`image`],childTemplate:[`image`],settings:[{control:`toggle`,label:`Caption`,setting:`showCaption`,default:!1,role:`content`},{control:`number`,label:`Columns`,setting:`columns`,default:3,min:1,max:8,step:1,role:`structure`},{control:`toggle`,label:`Crop images to fit`,setting:`imageCrop`,default:!0,role:`design`},{control:`select`,label:`Image aspect ratio`,setting:`aspectRatio`,default:`square`,role:`design`,when:{setting:`imageCrop`,equals:!0},options:[{value:`square`,label:`Square (1:1)`},{value:`4-3`,label:`Standard (4:3)`},{value:`3-2`,label:`Classic (3:2)`},{value:`16-9`,label:`Wide (16:9)`}]}],render(e,t){let n=Mn[String(t?.columns)]??`grid-cols-3`,i=t?.imageCrop===!1?``:` ${Nn[String(t?.aspectRatio)]??Nn.square} [&_img]:w-full [&_img]:object-cover`,a=r(e.caption);return`<figure data-pb-block="gallery"><div data-pb-children class="grid gap-3 ${n}${i}"></div>${t===void 0||t.showCaption===!0||a.trim()!==``?`<figcaption data-pb-rich="caption" class="mt-1.5 text-center text-sm text-neutral-500">${a}</figcaption>`:``}</figure>`}},In=`file`,Ln={label:`File`,category:`Media`,icon:`file`,placeholder:`File name…`,description:`Add a link to a downloadable file.`,supports:Vt,toolbar:[{control:`link`,label:`Link`,field:`href`,targetSetting:`linkTarget`,role:`content`},{control:`copy`,label:`Copy URL`,field:`href`,role:`content`},{control:`toggle-setting`,label:`Download button`,setting:`showDownloadButton`,role:`design`}],settings:[{control:`text`,label:`File URL`,field:`href`,placeholder:`https://…/file.pdf`,role:`content`},{control:`toggle`,label:`Show download button`,setting:`showDownloadButton`,default:!0,role:`design`},{control:`text`,label:`Download button text`,field:`downloadLabel`,role:`content`,when:{setting:`showDownloadButton`,equals:!0}},{control:`select`,label:`Open in`,setting:`linkTarget`,default:`none`,role:`content`,options:[{value:`none`,label:`Same tab`},{value:`_blank`,label:`New tab`}]}],render(e,t){let n=p(r(e.href)),i=t?.showDownloadButton===!1?` hidden`:``;return`<div data-pb-block="file" class="flex items-center justify-between gap-4 rounded-sm bg-neutral-100 px-4 py-3"><a data-pb-rich="name" data-pb-link="href" href="${n}"${t?.linkTarget===`_blank`?` target="_blank" rel="noopener"`:``} class="min-w-0 font-semibold [overflow-wrap:anywhere] text-inherit no-underline">${r(e.name)}</a><a href="${n}" download data-pb-text="downloadLabel" class="flex-none rounded-sm bg-[var(--color-accent,#3858e9)] px-3.5 py-1.5 text-[13px] font-semibold text-white no-underline${i}">${f(e.downloadLabel===void 0?`Download`:r(e.downloadLabel))}</a></div>`}},Rn={15:`grid-cols-[15%_1fr]`,20:`grid-cols-[20%_1fr]`,25:`grid-cols-[25%_1fr]`,30:`grid-cols-[30%_1fr]`,35:`grid-cols-[35%_1fr]`,40:`grid-cols-[40%_1fr]`,45:`grid-cols-[45%_1fr]`,50:`grid-cols-[50%_1fr]`,55:`grid-cols-[55%_1fr]`,60:`grid-cols-[60%_1fr]`,65:`grid-cols-[65%_1fr]`,70:`grid-cols-[70%_1fr]`,75:`grid-cols-[75%_1fr]`,80:`grid-cols-[80%_1fr]`,85:`grid-cols-[85%_1fr]`},zn={15:`grid-cols-[1fr_15%]`,20:`grid-cols-[1fr_20%]`,25:`grid-cols-[1fr_25%]`,30:`grid-cols-[1fr_30%]`,35:`grid-cols-[1fr_35%]`,40:`grid-cols-[1fr_40%]`,45:`grid-cols-[1fr_45%]`,50:`grid-cols-[1fr_50%]`,55:`grid-cols-[1fr_55%]`,60:`grid-cols-[1fr_60%]`,65:`grid-cols-[1fr_65%]`,70:`grid-cols-[1fr_70%]`,75:`grid-cols-[1fr_75%]`,80:`grid-cols-[1fr_80%]`,85:`grid-cols-[1fr_85%]`},Bn={top:`items-start`,center:`items-center`,bottom:`items-end`},Vn=`media-text`,Hn={label:`Media & Text`,category:`Media`,icon:`media-text`,description:`Set media and words side-by-side for a richer layout.`,supports:Bt,toolbar:[{control:`replace`,label:`Replace`,field:`media`},{control:`link`,label:`Link media`,setting:`href`,targetSetting:`linkTarget`,role:`content`},{control:`setting-options`,label:`Change media position`,setting:`mediaPosition`,options:[{value:`left`,label:`Left`},{value:`right`,label:`Right`}],role:`design`},{control:`setting-options`,label:`Change vertical alignment`,setting:`verticalAlignment`,options:[{value:`top`,label:`Top`},{value:`center`,label:`Center`},{value:`bottom`,label:`Bottom`}],role:`design`}],settings:[{control:`media`,label:`Media`,field:`media`,role:`content`},{control:`text`,label:`Media link URL`,setting:`href`,default:``,placeholder:`https://…`,role:`content`},{control:`select`,label:`Open media link in`,setting:`linkTarget`,default:`none`,role:`content`,when:{setting:`href`,notEquals:``},options:[{value:`none`,label:`Same tab`},{value:`_blank`,label:`New tab`}]},{control:`toggle-group`,label:`Media position`,setting:`mediaPosition`,default:`left`,role:`design`,options:[{value:`left`,label:`Left`},{value:`right`,label:`Right`}]},{control:`number`,label:`Media width (%)`,setting:`mediaWidth`,default:50,min:15,max:85,step:5,role:`design`},{control:`toggle`,label:`Stack on mobile`,setting:`stackOnMobile`,default:!0,role:`structure`},{control:`toggle-group`,label:`Vertical alignment`,setting:`verticalAlignment`,default:`center`,role:`design`,options:[{value:`top`,label:`Top`},{value:`center`,label:`Center`},{value:`bottom`,label:`Bottom`}]},{control:`toggle`,label:`Image fills the column`,setting:`imageFill`,default:!1,role:`design`}],render(e,t){let n=e.media??{},r=(n.width?` width="${p(n.width)}"`:``)+(n.height?` height="${p(n.height)}"`:``),i=t?.mediaPosition===`right`,a=(i?zn:Rn)[String(t?.mediaWidth)]??(i?zn[50]:Rn[50]),o=Bn[String(t?.verticalAlignment)]??`items-center`,s=t?.stackOnMobile===!1?``:` max-md:grid-cols-1`,c=t?.imageFill===!0?` [&_img]:h-full [&_img]:object-cover`:``,l=typeof t?.href==`string`?t.href.trim():``,u=t?.linkTarget===`_blank`?` target="_blank" rel="noopener"`:``,d=`<img data-pb-image="media" src="${p(n.src??``)}" alt="${p(n.alt??``)}"${r} class="block h-auto max-w-full">`,f=l?`<a href="${p(l)}"${u}>${d}</a>`:d;return`<div data-pb-block="media-text" class="grid gap-6 ${a} ${o}${s}"><div class="min-w-0${i?` order-2`:``}${c}">${f}</div><div data-pb-children class="min-w-0"></div></div>`}},Un={90:`rotate-90`,180:`rotate-180`,270:`rotate-[270deg]`},Wn=`<svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" class="size-5"><circle cx="10" cy="10" r="8"></circle></svg>`,Gn=`icon`,Kn={label:`Icon`,category:`Media`,icon:`icon`,description:`Display an inline SVG icon.`,supports:Bt,noSplit:[`svg`],allowedFormats:[],toolbar:[{control:`text`,label:`Accessible label`,setting:`ariaLabel`,role:`content`},{control:`setting-options`,label:`Change rotation`,setting:`rotation`,options:[{value:`0`,label:`0°`},{value:`90`,label:`90°`},{value:`180`,label:`180°`},{value:`270`,label:`270°`}],role:`design`},{control:`toggle-setting`,label:`Flip horizontally`,setting:`flipHorizontal`,role:`design`},{control:`toggle-setting`,label:`Flip vertically`,setting:`flipVertical`,role:`design`}],settings:[{control:`text`,label:`Accessible label`,setting:`ariaLabel`,default:``,role:`content`,help:`Describe the icon when it communicates meaning. Leave empty for decorative icons.`},{control:`select`,label:`Rotation`,setting:`rotation`,default:`0`,role:`design`,options:[{value:`0`,label:`0°`},{value:`90`,label:`90°`},{value:`180`,label:`180°`},{value:`270`,label:`270°`}]},{control:`toggle`,label:`Flip horizontally`,setting:`flipHorizontal`,default:!1,role:`design`},{control:`toggle`,label:`Flip vertically`,setting:`flipVertical`,default:!1,role:`design`}],render(e,t){let n=[Un[String(t?.rotation)]??``,t?.flipHorizontal===!0?`-scale-x-100`:``,t?.flipVertical===!0?`-scale-y-100`:``].filter(Boolean).join(` `),i=n?` class="${n}"`:``,a=typeof t?.ariaLabel==`string`?t.ariaLabel.trim():``;return`<span data-pb-block="icon" data-pb-rich="svg"${a?` role="img" aria-label="${p(a)}"`:` aria-hidden="true"`}${i}>${e.svg===void 0?Wn:r(e.svg)}</span>`}},qn={solid:`pbe-btn pbe-btn--solid`,outline:`pbe-btn pbe-btn--outline`,link:`pbe-btn pbe-btn--link`},Jn=`button`,Yn={label:`Button`,category:`Design`,icon:`button`,placeholder:`Add text…`,description:`Prompt visitors to take action with a button-style link.`,supports:zt,variations:[{name:`outline`,label:`Outline`,class:`bg-transparent text-current ring-1 ring-current`},{name:`link`,label:`Link`,class:`bg-transparent p-0 text-current underline`}],toolbar:[{control:`link`,label:`Link`,field:`url`,targetSetting:`linkTarget`,role:`content`}],settings:[{control:`toggle-group`,label:`Style`,setting:`style`,default:`solid`,role:`design`,options:[{value:`solid`,label:`Solid`},{value:`outline`,label:`Outline`},{value:`link`,label:`Link`}]},{control:`text`,label:`Link URL`,field:`url`,placeholder:`https://…`,role:`content`},{control:`select`,label:`Open in`,setting:`linkTarget`,default:`none`,role:`content`,options:[{value:`none`,label:`Same tab`},{value:`_blank`,label:`New tab`}]},{control:`text`,label:`Link rel`,setting:`rel`,default:``,placeholder:`e.g. nofollow`},{control:`text`,label:`Title attribute`,setting:`title`,default:``}],render(e,t){let n=qn[String(t?.style)]??qn.solid,i=[t?.linkTarget===`_blank`?`noopener`:``,typeof t?.rel==`string`?t.rel.trim():``].filter(Boolean).join(` `),a=(t?.linkTarget===`_blank`?` target="_blank"`:``)+(i?` rel="${p(i)}"`:``)+(typeof t?.title==`string`&&t.title.trim()?` title="${p(t.title.trim())}"`:``);return`<a data-pb-block="button" data-pb-rich="label" data-pb-link="url" href="${p(e.url===void 0?`#`:r(e.url))}"${a} class="${n}">${r(e.label)}</a>`}},Xn={start:`justify-start`,center:`justify-center`,end:`justify-end`,between:`justify-between`},Zn={none:`pbe-buttons--gap-none`,sm:`pbe-buttons--gap-sm`,md:`pbe-buttons--gap-md`,lg:`pbe-buttons--gap-lg`},Qn=`buttons`,$n={label:`Buttons`,category:`Design`,icon:`buttons`,description:`Prompt visitors to take action with a group of button-style links.`,supports:Bt,allowedChildren:[`button`],childTemplate:[`button`],toolbar:[{control:`setting-options`,label:`Change orientation`,setting:`orientation`,options:[{value:`row`,label:`Horizontal`},{value:`column`,label:`Vertical`}],role:`design`},{control:`setting-options`,label:`Change justification`,setting:`justify`,options:[{value:`start`,label:`Left`},{value:`center`,label:`Center`},{value:`end`,label:`Right`},{value:`between`,label:`Space between`}],role:`design`},{control:`add-child`,label:`Add button`,type:`button`}],settings:[{control:`toggle-group`,label:`Orientation`,setting:`orientation`,default:`row`,role:`design`,options:[{value:`row`,label:`Horizontal`},{value:`column`,label:`Vertical`}]},{control:`toggle-group`,label:`Justification`,setting:`justify`,default:`start`,role:`design`,options:[{value:`start`,label:`Left`},{value:`center`,label:`Center`},{value:`end`,label:`Right`},{value:`between`,label:`Space between`}]},{control:`toggle-group`,label:`Gap`,setting:`gap`,default:`sm`,role:`design`,options:[{value:`none`,label:`None`},{value:`sm`,label:`Small`},{value:`md`,label:`Medium`},{value:`lg`,label:`Large`}]}],render(e,t){let n=Xn[String(t?.justify)]??`justify-start`,r=Zn[String(t?.gap)]??Zn.sm;return`<div data-pb-block="buttons" data-pb-children class="flex ${t?.orientation===`column`?`flex-col`:`flex-row flex-wrap`} items-center ${n} ${r}"></div>`}},er=`separator`,tr={label:`Separator`,category:`Design`,icon:`separator`,description:`Create a break between ideas or sections with a horizontal separator.`,supports:Vt,toolbar:[],variations:[{name:`wide`,label:`Wide`,class:`mx-auto w-1/2`},{name:`dots`,label:`Dots`,class:`border-t-4 border-dotted`}],render(){return`<hr data-pb-block="separator" class="border-0 border-t border-neutral-300">`}},nr={sm:`pbe-spacer--sm`,md:`pbe-spacer--md`,lg:`pbe-spacer--lg`,xl:`pbe-spacer--xl`},rr=`spacer`,ir={label:`Spacer`,category:`Design`,icon:`spacer`,description:`Add white space between blocks.`,supports:{spacing:{margin:!0},dimensions:{width:{default:!1},height:!0}},toolbar:[{control:`setting-options`,label:`Change height`,setting:`height`,options:[{value:`sm`,label:`S`},{value:`md`,label:`M`},{value:`lg`,label:`L`},{value:`xl`,label:`XL`}],role:`design`}],settings:[{control:`toggle-group`,label:`Height`,setting:`height`,default:`md`,role:`design`,options:[{value:`sm`,label:`S`},{value:`md`,label:`M`},{value:`lg`,label:`L`},{value:`xl`,label:`XL`}]}],render(e,t){return`<div data-pb-block="spacer" aria-hidden="true" class="pbe-spacer block ${nr[String(t?.height)]??nr.md}"></div>`}},ar=`accordion`,or={label:`Accordion`,category:`Design`,icon:`accordion`,description:`A vertically stacked set of collapsible content sections.`,supports:Bt,toolbar:[{control:`toggle-setting`,label:`Show icons`,setting:`showIcon`,role:`design`},{control:`setting-options`,label:`Change icon position`,setting:`iconPosition`,role:`design`,options:[{value:`start`,label:`Start`},{value:`end`,label:`End`}]},{control:`add-child`,label:`Add item`,type:`accordion-item`}],settings:[{control:`toggle`,label:`Show icons`,setting:`showIcon`,default:!0,role:`design`},{control:`toggle-group`,label:`Icon position`,setting:`iconPosition`,default:`start`,role:`design`,when:{setting:`showIcon`,equals:!0},options:[{value:`start`,label:`Start`},{value:`end`,label:`End`}]}],allowedChildren:[`accordion-item`],childTemplate:[`accordion-item`],render(e,t){return`<div data-pb-block="accordion" data-pb-children class="pbe-accordion flex flex-col [&>details+details]:border-t-0${t?.showIcon===!1?``:t?.iconPosition===`end`?` pbe-accordion--icons-end`:` pbe-accordion--icons-start`}"></div>`}},sr=`accordion-item`,cr={label:`Accordion item`,category:`Design`,icon:`details`,internal:!0,placeholder:`Accordion title`,toolbar:[{control:`toggle-setting`,label:`Open by default`,setting:`openByDefault`,role:`structure`}],settings:[{control:`toggle`,label:`Open by default`,setting:`openByDefault`,default:!1,role:`structure`,help:`Keep this item expanded when the page first loads.`}],render(e,t){return`<details data-pb-block="accordion-item" class="border border-neutral-300 px-4 py-3"${t?.openByDefault===!0?` open`:``}><summary data-pb-rich="title" class="cursor-pointer font-semibold">${r(e.title)}</summary><div data-pb-children class="mt-2"></div></details>`}},lr=`embed`,ur={label:`Embed`,category:`Widgets`,icon:`globe`,placeholder:`Add caption`,description:`Embed external content — videos, maps, posts — via its embed URL.`,supports:Vt,toolbar:[{control:`replace`,label:`Replace`,field:`media`},{control:`caption`,label:`Caption`,field:`caption`,setting:`showCaption`}],settings:[{control:`media`,label:`Embed`,field:`media`,role:`content`},{control:`toggle`,label:`Caption`,setting:`showCaption`,default:!1,role:`content`},{control:`toggle`,label:`Responsive (16:9)`,setting:`responsive`,default:!0}],render(e,t){let n=e.media??{},i=(n.width?` width="${p(n.width)}"`:``)+(n.height?` height="${p(n.height)}"`:``),a=t?.responsive===!1?``:` class="aspect-video w-full"`,o=r(e.caption),s=t===void 0||t.showCaption===!0||o.trim()!==``?`<figcaption data-pb-rich="caption" class="mt-1.5 text-center text-sm text-neutral-500">${o}</figcaption>`:``;return`<figure data-pb-block="embed"><iframe data-pb-image="media" src="${p(n.src??``)}" alt="${p(n.alt??``)}"${i}${a} loading="lazy" allowfullscreen></iframe>${s}</figure>`}},dr=`social-links`,fr={label:`Social links`,category:`Widgets`,icon:`share`,description:`Display links to your social media profiles.`,supports:Bt,toolbar:[{control:`setting-options`,label:`Change icon size`,setting:`size`,role:`design`,options:[{value:`small`,label:`Small`},{value:`normal`,label:`Normal`},{value:`large`,label:`Large`}]},{control:`toggle-setting`,label:`Show labels`,setting:`showLabels`,role:`design`},{control:`add-child`,label:`Add social icon`,type:`social-link`}],variations:[{name:`logos`,label:`Logos only`,class:`gap-4`},{name:`pill`,label:`Pill`,class:`rounded-full bg-neutral-100 px-4 py-2`}],allowedChildren:[`social-link`],childTemplate:[`social-link`],settings:[{control:`toggle-group`,label:`Icon size`,setting:`size`,default:`normal`,role:`design`,options:[{value:`small`,label:`Small`},{value:`normal`,label:`Normal`},{value:`large`,label:`Large`}]},{control:`toggle`,label:`Show text labels`,setting:`showLabels`,default:!1,role:`design`,help:`Show each social icon's accessible label next to the icon.`}],render(e,t){return`<div data-pb-block="social-links" data-pb-children class="flex flex-wrap items-center gap-3 ${t?.size===`small`?`[&_svg]:size-5`:t?.size===`large`?`[&_svg]:size-8`:`[&_svg]:size-6`}${t?.showLabels===!0?` pbe-social-links--show-labels`:``}"></div>`}},pr={chain:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M13.75 10.25a3.5 3.5 0 0 1 0 4.95l-2.55 2.55a3.5 3.5 0 0 1-4.95-4.95l1.3-1.3"/><path d="M10.25 13.75a3.5 3.5 0 0 1 0-4.95l2.55-2.55a3.5 3.5 0 0 1 4.95 4.95l-1.3 1.3"/></g>`,mail:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3.75 7l8.25 6.25L20.25 7"/></g>`,feed:`<circle cx="6.25" cy="17.75" r="1.9" fill="currentColor" stroke="none"/><g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 11.25a8.25 8.25 0 0 1 8.25 8.25"/><path d="M4.5 4.75A14.75 14.75 0 0 1 19.25 19.5"/></g>`,bluesky:`<path d="M5.202 2.857C7.954 4.922 10.913 9.11 12 11.358c1.087-2.247 4.046-6.436 6.798-8.501C20.783 1.366 24 .213 24 3.883c0 .732-.42 6.156-.667 7.037-.856 3.061-3.978 3.842-6.755 3.37 4.854.826 6.089 3.562 3.422 6.299-5.065 5.196-7.28-1.304-7.847-2.97-.104-.305-.152-.448-.153-.327 0-.121-.05.022-.153.327-.568 1.666-2.782 8.166-7.847 2.97-2.667-2.737-1.432-5.473 3.422-6.3-2.777.473-5.899-.308-6.755-3.369C.42 10.04 0 4.615 0 3.883c0-3.67 3.217-2.517 5.202-1.026"/>`,facebook:`<path d="M9.101 23.691v-7.98H6.627v-3.667h2.474v-1.58c0-4.085 1.848-5.978 5.858-5.978.401 0 .955.042 1.468.103a8.68 8.68 0 0 1 1.141.195v3.325a8.623 8.623 0 0 0-.653-.036 26.805 26.805 0 0 0-.733-.009c-.707 0-1.259.096-1.675.309a1.686 1.686 0 0 0-.679.622c-.258.42-.374.995-.374 1.752v1.297h3.919l-.386 2.103-.287 1.564h-3.246v8.245C19.396 23.238 24 18.179 24 12.044c0-6.627-5.373-12-12-12s-12 5.373-12 12c0 5.628 3.874 10.35 9.101 11.647Z"/>`,github:`<path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/>`,instagram:`<path d="M7.0301.084c-1.2768.0602-2.1487.264-2.911.5634-.7888.3075-1.4575.72-2.1228 1.3877-.6652.6677-1.075 1.3368-1.3802 2.127-.2954.7638-.4956 1.6365-.552 2.914-.0564 1.2775-.0689 1.6882-.0626 4.947.0062 3.2586.0206 3.6671.0825 4.9473.061 1.2765.264 2.1482.5635 2.9107.308.7889.72 1.4573 1.388 2.1228.6679.6655 1.3365 1.0743 2.1285 1.38.7632.295 1.6361.4961 2.9134.552 1.2773.056 1.6884.069 4.9462.0627 3.2578-.0062 3.668-.0207 4.9478-.0814 1.28-.0607 2.147-.2652 2.9098-.5633.7889-.3086 1.4578-.72 2.1228-1.3881.665-.6682 1.0745-1.3378 1.3795-2.1284.2957-.7632.4966-1.636.552-2.9124.056-1.2809.0692-1.6898.063-4.948-.0063-3.2583-.021-3.6668-.0817-4.9465-.0607-1.2797-.264-2.1487-.5633-2.9117-.3084-.7889-.72-1.4568-1.3876-2.1228C21.2982 1.33 20.628.9208 19.8378.6165 19.074.321 18.2017.1197 16.9244.0645 15.6471.0093 15.236-.005 11.977.0014 8.718.0076 8.31.0215 7.0301.0839m.1402 21.6932c-1.17-.0509-1.8053-.2453-2.2287-.408-.5606-.216-.96-.4771-1.3819-.895-.422-.4178-.6811-.8186-.9-1.378-.1644-.4234-.3624-1.058-.4171-2.228-.0595-1.2645-.072-1.6442-.079-4.848-.007-3.2037.0053-3.583.0607-4.848.05-1.169.2456-1.805.408-2.2282.216-.5613.4762-.96.895-1.3816.4188-.4217.8184-.6814 1.3783-.9003.423-.1651 1.0575-.3614 2.227-.4171 1.2655-.06 1.6447-.072 4.848-.079 3.2033-.007 3.5835.005 4.8495.0608 1.169.0508 1.8053.2445 2.228.408.5608.216.96.4754 1.3816.895.4217.4194.6816.8176.9005 1.3787.1653.4217.3617 1.056.4169 2.2263.0602 1.2655.0739 1.645.0796 4.848.0058 3.203-.0055 3.5834-.061 4.848-.051 1.17-.245 1.8055-.408 2.2294-.216.5604-.4763.96-.8954 1.3814-.419.4215-.8181.6811-1.3783.9-.4224.1649-1.0577.3617-2.2262.4174-1.2656.0595-1.6448.072-4.8493.079-3.2045.007-3.5825-.006-4.848-.0608M16.953 5.5864A1.44 1.44 0 1 0 18.39 4.144a1.44 1.44 0 0 0-1.437 1.4424M5.8385 12.012c.0067 3.4032 2.7706 6.1557 6.173 6.1493 3.4026-.0065 6.157-2.7701 6.1506-6.1733-.0065-3.4032-2.771-6.1565-6.174-6.1498-3.403.0067-6.156 2.771-6.1496 6.1738M8 12.0077a4 4 0 1 1 4.008 3.9921A3.9996 3.9996 0 0 1 8 12.0077"/>`,linkedin:`<path d="M20.447 20.452h-3.554v-5.569c0-1.328-.027-3.037-1.852-3.037-1.853 0-2.136 1.445-2.136 2.939v5.667H9.351V9h3.414v1.561h.046c.477-.9 1.637-1.85 3.37-1.85 3.601 0 4.267 2.37 4.267 5.455v6.286zM5.337 7.433c-1.144 0-2.063-.926-2.063-2.065 0-1.138.92-2.063 2.063-2.063 1.14 0 2.064.925 2.064 2.063 0 1.139-.925 2.065-2.064 2.065zm1.782 13.019H3.555V9h3.564v11.452zM22.225 0H1.771C.792 0 0 .774 0 1.729v20.542C0 23.227.792 24 1.771 24h20.451C23.2 24 24 23.227 24 22.271V1.729C24 .774 23.2 0 22.222 0h.003z"/>`,mastodon:`<path d="M23.268 5.313c-.35-2.578-2.617-4.61-5.304-5.004C17.51.242 15.792 0 11.813 0h-.03c-3.98 0-4.835.242-5.288.309C3.882.692 1.496 2.518.917 5.127.64 6.412.61 7.837.661 9.143c.074 1.874.088 3.745.26 5.611.118 1.24.325 2.47.62 3.68.55 2.237 2.777 4.098 4.96 4.857 2.336.792 4.849.923 7.256.38.265-.061.527-.132.786-.213.585-.184 1.27-.39 1.774-.753a.057.057 0 0 0 .023-.043v-1.809a.052.052 0 0 0-.02-.041.053.053 0 0 0-.046-.01 20.282 20.282 0 0 1-4.709.545c-2.73 0-3.463-1.284-3.674-1.818a5.593 5.593 0 0 1-.319-1.433.053.053 0 0 1 .066-.054c1.517.363 3.072.546 4.632.546.376 0 .75 0 1.125-.01 1.57-.044 3.224-.124 4.768-.422.038-.008.077-.015.11-.024 2.435-.464 4.753-1.92 4.989-5.604.008-.145.03-1.52.03-1.67.002-.512.167-3.63-.024-5.545zm-3.748 9.195h-2.561V8.29c0-1.309-.55-1.976-1.67-1.976-1.23 0-1.846.79-1.846 2.35v3.403h-2.546V8.663c0-1.56-.617-2.35-1.848-2.35-1.112 0-1.668.668-1.67 1.977v6.218H4.822V8.102c0-1.31.337-2.35 1.011-3.12.696-.77 1.608-1.164 2.74-1.164 1.311 0 2.302.5 2.962 1.498l.638 1.06.638-1.06c.66-.999 1.65-1.498 2.96-1.498 1.13 0 2.043.395 2.74 1.164.675.77 1.012 1.81 1.012 3.12z"/>`,tiktok:`<path d="M12.525.02c1.31-.02 2.61-.01 3.91-.02.08 1.53.63 3.09 1.75 4.17 1.12 1.11 2.7 1.62 4.24 1.79v4.03c-1.44-.05-2.89-.35-4.2-.97-.57-.26-1.1-.59-1.62-.93-.01 2.92.01 5.84-.02 8.75-.08 1.4-.54 2.79-1.35 3.94-1.31 1.92-3.58 3.17-5.91 3.21-1.43.08-2.86-.31-4.08-1.03-2.02-1.19-3.44-3.37-3.65-5.71-.02-.5-.03-1-.01-1.49.18-1.9 1.12-3.72 2.58-4.96 1.66-1.44 3.98-2.13 6.15-1.72.02 1.48-.04 2.96-.04 4.44-.99-.32-2.15-.23-3.02.37-.63.41-1.11 1.04-1.36 1.75-.21.51-.15 1.07-.14 1.61.24 1.64 1.82 3.02 3.5 2.87 1.12-.01 2.19-.66 2.77-1.61.19-.33.4-.67.41-1.06.1-1.79.06-3.57.07-5.36.01-4.03-.01-8.05.02-12.07z"/>`,x:`<path d="M14.234 10.162 22.977 0h-2.072l-7.591 8.824L7.251 0H.258l9.168 13.343L.258 24H2.33l8.016-9.318L16.749 24h6.993zm-2.837 3.299-.929-1.329L3.076 1.56h3.182l5.965 8.532.929 1.329 7.754 11.09h-3.182z"/>`,youtube:`<path d="M23.498 6.186a3.016 3.016 0 0 0-2.122-2.136C19.505 3.545 12 3.545 12 3.545s-7.505 0-9.377.505A3.017 3.017 0 0 0 .502 6.186C0 8.07 0 12 0 12s0 3.93.502 5.814a3.016 3.016 0 0 0 2.122 2.136c1.871.505 9.376.505 9.376.505s7.505 0 9.377-.505a3.015 3.015 0 0 0 2.122-2.136C24 15.93 24 12 24 12s0-3.93-.502-5.814zM9.545 15.568V8.432L15.818 12l-6.273 3.568z"/>`},mr=Object.keys(pr),hr={chain:`Link`,mail:`Mail`,feed:`RSS feed`,github:`GitHub`,x:`X`,facebook:`Facebook`,instagram:`Instagram`,linkedin:`LinkedIn`,youtube:`YouTube`,mastodon:`Mastodon`,bluesky:`Bluesky`,tiktok:`TikTok`},gr=`social-link`,_r={label:`Social icon`,category:`Widgets`,icon:`share`,internal:!0,supports:Bt,toolbar:[{control:`text`,label:`Accessible label`,setting:`ariaLabel`,role:`content`},{control:`link`,label:`Link`,field:`url`,targetSetting:`linkTarget`,role:`content`},{control:`setting-options`,label:`Change service`,setting:`service`,options:mr.map(e=>({value:e,label:hr[e]??e})),role:`content`},{control:`toggle-setting`,label:`Show label`,setting:`showLabel`,role:`content`}],settings:[{control:`select`,label:`Service`,setting:`service`,default:`chain`,role:`content`,options:mr.map(e=>({value:e,label:hr[e]??e}))},{control:`text`,label:`Profile URL`,field:`url`,placeholder:`https://…`,role:`content`},{control:`toggle`,label:`Show text label`,setting:`showLabel`,default:!1,role:`content`},{control:`text`,label:`Accessible label`,setting:`ariaLabel`,default:``,role:`content`},{control:`select`,label:`Open in`,setting:`linkTarget`,default:`none`,role:`content`,options:[{value:`none`,label:`Same tab`},{value:`_blank`,label:`New tab`}]},{control:`text`,label:`Link rel`,setting:`rel`,default:``,role:`advanced`,placeholder:`e.g. me nofollow`}],render(e,t){let n=pr[String(t?.service)]?String(t?.service):`chain`,r=typeof e.url==`string`?e.url:``,i=typeof t?.ariaLabel==`string`&&t.ariaLabel.trim()?t.ariaLabel.trim():hr[n]??n,a=[t?.linkTarget===`_blank`?`noopener`:``,typeof t?.rel==`string`?t.rel.trim():``].filter(Boolean).join(` `),o=(t?.linkTarget===`_blank`?` target="_blank"`:``)+(a?` rel="${p(a)}"`:``),s=t?.showLabel===!0?` pbe-social-link--show-label`:``;return`<a data-pb-block="social-link" data-pb-link="url" href="${p(r)}"${o} aria-label="${p(i)}" class="inline-flex items-center gap-2 text-current${s}"><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" class="size-6 fill-current">${pr[n]}</svg><span class="pbe-social-label">${p(i)}</span></a>`}},vr=`html`,yr={label:`Custom HTML`,category:`Widgets`,icon:`html`,placeholder:`Write HTML…`,description:`Add custom HTML markup.`,allowedFormats:[],toolbar:[],render(e){return`<div data-pb-block="html" data-pb-rich="content">${r(e.content)}</div>`}},br=`pattern`,xr={label:`Pattern`,icon:`pattern`,description:`A pattern instance. Edits here never change the original design.`,internal:!0,phantom:!0,render(){return`<div data-pb-block="pattern" data-pb-children></div>`}},Sr={top:`items-start`,center:`items-center`,bottom:`items-end`},Cr={none:`pbe-columns--gap-none`,sm:`pbe-columns--gap-sm`,md:`pbe-columns--gap-md`,lg:`pbe-columns--gap-lg`},wr=`columns`,Tr={label:`Columns`,category:`Design`,icon:`columns`,description:`Display content in multiple columns.`,supports:Bt,allowedChildren:[`column`],childTemplate:[`column`,`column`],toolbar:[{control:`setting-options`,label:`Change vertical alignment`,setting:`valign`,options:[{value:`top`,label:`Top`},{value:`center`,label:`Center`},{value:`bottom`,label:`Bottom`}],role:`design`},{control:`add-child`,label:`Add column`,type:`column`}],settings:[{control:`toggle-group`,label:`Vertical alignment`,setting:`valign`,default:`top`,role:`design`,options:[{value:`top`,label:`Top`},{value:`center`,label:`Center`},{value:`bottom`,label:`Bottom`}]},{control:`toggle-group`,label:`Gap`,setting:`gap`,default:`md`,role:`design`,options:[{value:`none`,label:`None`},{value:`sm`,label:`Small`},{value:`md`,label:`Medium`},{value:`lg`,label:`Large`}]},{control:`toggle`,label:`Stack on mobile`,setting:`stackOnMobile`,default:!0,role:`structure`}],render(e,t){return`<div data-pb-block="columns" data-pb-children class="flex ${Sr[String(t?.valign)]??`items-start`} ${Cr[String(t?.gap)]??Cr.md}${t?.stackOnMobile===!1?``:` max-md:flex-col`}"></div>`}},Er={auto:`pbe-column--auto`,25:`pbe-column--25`,33:`pbe-column--33`,50:`pbe-column--50`,66:`pbe-column--66`,75:`pbe-column--75`},Dr={top:`self-start`,center:`self-center`,bottom:`self-end`,stretch:`self-stretch`},Or=`column`,kr={label:`Column`,category:`Design`,icon:`column`,internal:!0,supports:{...Bt,dimensions:{minWidth:{default:!1},flexBasis:!0}},toolbar:[{control:`style-options`,label:`Change width`,style:`flexBasis`,options:[{value:`auto`,label:`Auto`},{value:`25%`,label:`25%`},{value:`33.333333%`,label:`33%`},{value:`50%`,label:`50%`},{value:`66.666667%`,label:`66%`},{value:`75%`,label:`75%`}],role:`design`},{control:`setting-options`,label:`Change vertical alignment`,setting:`valign`,options:[{value:`inherit`,label:`Inherit`},{value:`top`,label:`Top`},{value:`center`,label:`Center`},{value:`bottom`,label:`Bottom`},{value:`stretch`,label:`Stretch`}],role:`design`}],settings:[{control:`toggle-group`,label:`Width`,setting:`width`,default:`auto`,role:`structure`,options:[{value:`auto`,label:`Auto`},{value:`25`,label:`25%`},{value:`33`,label:`33%`},{value:`50`,label:`50%`},{value:`66`,label:`66%`},{value:`75`,label:`75%`}]},{control:`toggle-group`,label:`Vertical alignment`,setting:`valign`,default:`inherit`,role:`design`,options:[{value:`inherit`,label:`Inherit`},{value:`top`,label:`Top`},{value:`center`,label:`Center`},{value:`bottom`,label:`Bottom`},{value:`stretch`,label:`Stretch`}]}],render(e,t){let n=[`min-w-0`,Er[String(t?.width)]??Er.auto],r=Dr[String(t?.valign)];return r&&n.push(r),`<div data-pb-block="column" data-pb-children class="${n.join(` `)}"></div>`}},Ar={control:`toggle-group`,label:`Transform to`,transform:!0,role:`structure`,options:[{value:`group`,label:`Group`,icon:`group`},{value:`row`,label:`Row`,icon:`row`},{value:`stack`,label:`Stack`,icon:`stack`},{value:`grid`,label:`Grid`,icon:`grid`}]},jr=[`div`,`header`,`main`,`section`,`article`,`aside`,`footer`,`nav`,`dl`],Mr={control:`toggle-group`,label:`HTML element`,field:`tag`,role:`structure`,options:jr.map(e=>({value:e,label:e}))};function Nr(e,t,n,r){let i={...Bt,layout:{...Bt.layout,...e===`row`?{flexWrap:!0}:{},...e===`grid`?{gridColumns:{values:[`1`,`2`,`3`,`4`,`5`,`6`],allowCustom:!0}}:{}}},a=e===`group`?[]:[{control:`style-options`,label:`Change justification`,style:`justifyContent`,options:B.map(({key:e,label:t})=>({value:e,label:t}))},{control:`style-options`,label:`Change vertical alignment`,style:`alignItems`,options:Se.map(({key:e,label:t})=>({value:e,label:t}))},...e===`row`?[{control:`style-options`,label:`Change wrapping`,style:`flexWrap`,options:V.map(({key:e,label:t})=>({value:e,label:t}))}]:[],...e===`grid`?[{control:`style-options`,label:`Change columns`,style:`gridColumns`,options:[`1`,`2`,`3`,`4`,`5`,`6`].map(e=>({value:e,label:e}))}]:[]];return{label:t,category:`Design`,icon:e,description:n,supports:i,toolbar:[{control:`transform-options`,label:`Change layout`,options:Ar.options},...a],settings:[Ar,Mr],render(t){let n=typeof t.tag==`string`&&jr.includes(t.tag)?t.tag:`div`;return`<${n} data-pb-block="${e}" data-pb-tag="tag"${r?` class="${r}"`:``} data-pb-children></${n}>`}}}var Pr=`group`,Fr=Nr(Pr,`Group`,`Gather blocks in a layout container.`,``),Ir=Nr(`row`,`Row`,`Arrange blocks horizontally.`,`flex flex-row [&>*]:flex-1`),Lr=`stack`,Rr=Nr(Lr,`Stack`,`Arrange blocks vertically.`,`flex flex-col`),zr=`grid`,Br=Nr(zr,`Grid`,`Arrange blocks in a grid.`,`grid pbe-grid--2`),Vr=[[`hero`,{label:`Hero`,category:`Banners`,icon:`cover`,description:`Big opening headline with supporting copy and a pair of calls to action.`,content:`
<section data-pb-block="group" data-pb-tag="tag" data-pb-children class="text-center">
  <h1 data-pb-block="heading" data-pb-tag="level" data-pb-rich="text">Tell your story</h1>
  <p data-pb-block="paragraph" data-pb-rich="body">Introduce the big idea in a sentence or two, then invite people to dig in.</p>
  <div data-pb-block="buttons" data-pb-children><script type="application/json" data-pb-settings>{"justify":"center"}<\/script>
    <a data-pb-block="button" data-pb-rich="label" data-pb-link="url" href="#">Get started</a>
    <a data-pb-block="button" data-pb-rich="label" data-pb-link="url" href="#"><script type="application/json" data-pb-settings>{"style":"outline"}<\/script>Learn more</a>
  </div>
</section>`}],[`call-to-action`,{label:`Call to action`,category:`Call to action`,icon:`buttons`,description:`Heading, one persuasive line, and a button.`,content:`
<section data-pb-block="group" data-pb-tag="tag" data-pb-children class="text-center">
  <h2 data-pb-block="heading" data-pb-tag="level" data-pb-rich="text">Ready when you are</h2>
  <p data-pb-block="paragraph" data-pb-rich="body">One line that removes the last doubt.</p>
  <div data-pb-block="buttons" data-pb-children><script type="application/json" data-pb-settings>{"justify":"center"}<\/script>
    <a data-pb-block="button" data-pb-rich="label" data-pb-link="url" href="#">Start now</a>
  </div>
</section>`}],[`features`,{label:`Feature columns`,category:`Columns`,icon:`columns`,description:`Three columns, each a small heading over a short explanation.`,content:`
<div data-pb-block="columns" data-pb-children>
  <div data-pb-block="column" data-pb-children>
    <h3 data-pb-block="heading" data-pb-tag="level" data-pb-rich="text">Fast</h3>
    <p data-pb-block="paragraph" data-pb-rich="body">Explain the first thing people get.</p>
  </div>
  <div data-pb-block="column" data-pb-children>
    <h3 data-pb-block="heading" data-pb-tag="level" data-pb-rich="text">Simple</h3>
    <p data-pb-block="paragraph" data-pb-rich="body">Explain the second thing people get.</p>
  </div>
  <div data-pb-block="column" data-pb-children>
    <h3 data-pb-block="heading" data-pb-tag="level" data-pb-rich="text">Yours</h3>
    <p data-pb-block="paragraph" data-pb-rich="body">Explain the third thing people get.</p>
  </div>
</div>`}],[`testimonials`,{label:`Two testimonials`,category:`Testimonials`,icon:`quote`,description:`A heading over two quoted voices side by side.`,content:`
<h2 data-pb-block="heading" data-pb-tag="level" data-pb-rich="text" class="text-center">What people say</h2>
<div data-pb-block="columns" data-pb-children>
  <div data-pb-block="column" data-pb-children>
    <blockquote data-pb-block="quote"><div data-pb-rich="body">Exactly the tool I did not know I needed.</div><cite data-pb-text="citation">Alex, maker</cite></blockquote>
  </div>
  <div data-pb-block="column" data-pb-children>
    <blockquote data-pb-block="quote"><div data-pb-rich="body">Set up in minutes, shipped the same day.</div><cite data-pb-text="citation">Sam, founder</cite></blockquote>
  </div>
</div>`}]];function Hr(){for(let[e,t]of Vr)Et(e,t)}var Ur=[[Ut,Wt],[Gt,Kt],[Yt,Xt],[Zt,Qt],[$t,en],[tn,nn],[rn,an],[on,sn],[cn,ln],[dn,fn],[pn,mn],[gn,_n],[yn,bn],[Sn,Cn],[Tn,En],[An,jn],[Pn,Fn],[In,Ln],[Vn,Hn],[Gn,Kn],[Jn,Yn],[Qn,$n],[er,tr],[rr,ir],[ar,or],[sr,cr],[lr,ur],[dr,fr],[gr,_r],[vr,yr],[wr,Tr],[Or,kr],[Pr,Fr],[`row`,Ir],[Lr,Rr],[zr,Br],[br,xr]];function Wr(){for(let[e,t]of Ur)tt(e,t)}var Gr=Symbol(),Kr=Symbol(),qr=e=>e&&typeof e==`object`?e[Kr]:void 0,Jr=(e,t)=>e[1]?e[1]+`.`+String(t):String(t),Yr=(e,t,n)=>{if(!(!e||typeof e!=`object`||e[Kr]))try{Object.defineProperty(e,Kr,{value:[t,n],configurable:!0})}catch{}},Xr=100,Zr=null,Qr=null,$r=!1,ei=0,ti=new WeakMap,ni=new Set,ri=null,ii=e=>{ri=e},ai=(e,t)=>{if(!Zr)return;let n=ti.get(e);n||ti.set(e,n=new Map);let r=n.get(t);r||n.set(t,r=new Set),r.add(Zr),Zr.d.push(r)},oi=(e,t,n,r)=>{if(Zr?.g)throw Error(`Computed getter '${Zr.g}' must be pure`);let i=ti.get(e)?.get(t);if(i){for(let e of i)ni.add(e);$r||($r=!0,queueMicrotask(si))}ri?.(e,t,n,r)},si=()=>{try{for(;ni.size;){if(++ei>Xr){let e=[...ni].slice(-3).map(e=>e.l||`?`).join(`, `);throw ni.clear(),Error(`Infinite update loop: ${e}`)}let e=[...ni];ni.clear();for(let t of e)t.s?.();for(let t of e)t.s||t.r()}}finally{$r=!1,ei=0}},ci=e=>{for(let t of e.d)t.delete(e);e.d.length=0},J=(e,t)=>{let n,r={d:[],x:!1,l:t?.label??null,s:t?.scheduler??null,g:null,r(){if(r.x)return n;ci(r);let t=Zr;Zr=r;try{n=e()}finally{Zr=t}return n}};Qr?.e.push(r),t?.lazy||r.r();let i=r.r;return i._e=r,i},li=()=>({e:[],c:[]}),ui=(e,t)=>{let n=Qr;Qr=e;try{return t()}finally{Qr=n}},di=e=>{for(let t of e.e)ci(t),t.x=!0;for(let t of e.c)t();e.e.length=0,e.c.length=0},fi=e=>{Qr?.c.push(e)},pi=()=>Qr,mi=e=>{let t=Zr;Zr=null;try{return e()}finally{Zr=t}},hi=[],gi=[],_i=[],vi=[],yi=[],bi=(e,t,n)=>{for(let r of e)r(t,n)},xi=(e,t)=>e.getAttribute(t),Si=e=>typeof e==`function`,Ci=e=>typeof e==`object`,wi=e=>e==null?``:String(e),Ti=(e,t,n)=>{let r=wi(n);e[t]!==r&&(e[t]=r)},Ei=(e,t,n,r)=>{e.addEventListener(t,n,r),fi(()=>e.removeEventListener(t,n,r))},Di=new WeakMap,Oi=new WeakMap,ki=e=>{if(Array.isArray(e))return!0;let t=Object.getPrototypeOf(e);return t===Object.prototype||t===null},Ai=(e,t,n)=>{let r,i=J(()=>n.call(e),{lazy:!0,label:t,scheduler(){let n=i();if(n!==r){let i=r;r=n,oi(e,t,i,n)}}});i._e.g=t,r=i();let a=Oi.get(e);a||Oi.set(e,a=new Set),a.add(t),Object.defineProperty(e,t,{get(){return ai(e,t),r},enumerable:!0,configurable:!0})},ji=e=>{for(let[t,n]of Object.entries(Object.getOwnPropertyDescriptors(e)))if(n.get&&!n.set&&n.configurable){let r=n.get;queueMicrotask(()=>Ai(e,t,r))}},Mi=e=>{if(e===null||!Ci(e)||e[Gr]||!ki(e))return e;bi(hi,e);let t=Di.get(e);if(t)return t;ji(e);let n=new Proxy(e,{get(e,t,n){if(t===Gr)return e;ai(e,t);let r=Reflect.get(e,t,n);if(r&&Ci(r)){if(e[Kr]&&!r[Kr]&&ki(r)){let n=qr(e);Yr(r,n[0],Jr(n,t))}for(let t of _i)t(e,r)}return Mi(r)},set(e,t,n,r){let i=e[t],a=Array.isArray(e)?e.length:-1;for(let r of vi)r(e,t,i,n);let o=Reflect.set(e,t,n,r);return i!==n&&oi(e,t,i,n),a!==-1&&t!==`length`&&e.length!==a&&oi(e,`length`,a,e.length),o}});return Di.set(e,n),n},Ni=e=>e?.[Gr]??e,Pi=new Set;ii((e,t,n,r)=>{let i=Pi.size?qr(e):void 0;if(!i)return;let a=Jr(i,t),o={store:i[0],path:a,oldValue:n,newValue:r,isComputed:!!Oi.get(e)?.has(t),source:e};for(let[e,t]of[...Pi])e(i[0],a)&&t(o)});function Fi(...e){let[t,n]=e,r;if(Si(t))r=[()=>!0,t];else if(typeof t!=`string`||!Si(n))throw Error(`expected (fn) or (selector, fn)`);else{let e=t.indexOf(`.`),i=e<0?t:t.slice(0,e),a=e<0?null:t.slice(e+1);r=[(e,t)=>e===i&&(a==null||t===a||t.startsWith(a+`.`)),n]}return Pi.add(r),()=>Pi.delete(r)}var Ii=(e,t)=>{let n=t[1],r=t[2],i=Number(e),a=+r;return n===`eq`?String(e)===r:n===`ne`?String(e)!==r:n===`lt`?i<a:n===`gt`?i>a:n===`ge`?i>=a:n===`le`&&i<=a},Li=e=>e.replace(/^\$|^state\./,``),Ri=(e,t)=>t.trim().split(`.`).reduce((e,t)=>e?.[t],e),zi=(e,t)=>{let n=[];if(e)for(let r of e.split(`;`)){let e=r.indexOf(t);if(e<0)continue;let i=r.slice(0,e).trim(),a=r.slice(e+t.length).trim();i&&a&&n.push([i,a])}return n},Bi=e=>{let t=e.split(`|`),n=t[0].startsWith(`not:`);return n&&(t[0]=t[0].slice(4)),[t,n]},Vi=(e,t)=>{let n=null;for(let r=0;r<e.length;r++){let i=e[r];if(n){i===n&&(n=null);continue}if(i===`'`||i===`"`){n=i;continue}if(e.startsWith(t,r))return[e.slice(0,r),e.slice(r+t.length)]}return[e,null]},Hi=e=>{let t=/^\s*(['"])([^]*)\1\s*$/.exec(e);return t&&t[2]},Ui=`local:`,Wi=`data-p-store`,Gi=new Map,Ki=new Map,qi=(e,t)=>{outer:for(let n in t){let r=t[n],i=e[n];for(let e of yi)if(e(i,r))continue outer;if(r&&Ci(r)&&!Array.isArray(r)&&i&&Ci(i)){qi(i,r);continue}let a=Object.getOwnPropertyDescriptor(e,n);(!a||a.writable||a.set)&&(e[n]=r)}},Ji=(e,t)=>{if(t)try{qi(Ni(e),JSON.parse(t))}catch{}},Yi=(e,t,n)=>{let r=qr(Ni(e))?.[0];for(let i of Object.keys(t)){let a=t[i];if(Si(a)){if(i===`*`||i.startsWith(`*:`)){if(!r)continue;let e=i===`*`?null:i.slice(2);fi(Fi(r,t=>{e===`static`&&t.isComputed||e===`computed`&&!t.isComputed||a(t.newValue,t.oldValue,{path:t.path,el:n})}));continue}for(let t of i.split(`,`).map(e=>e.trim()).filter(Boolean)){let r,i=!1;J(()=>{let o=Ri(e,t);if(!i){r=o,i=!0;return}r!==o&&a(o,r,{path:t,el:n}),r=o},{label:t})}}}},Xi=e=>[e.state||{},e.actions||{},e.watch,e.setup],Zi=(e,t)=>{if(Si(t)){e&&Ki.set(e,t);return}let[n,r]=Xi(t);e&&Yr(n,e,``),bi(hi,n,e),bi(gi,r,e),e&&typeof document<`u`&&Ji(n,document.getElementById(`publr-state-`+e)?.textContent);let i=Mi(n);if(e&&Gi.set(e,[i,r]),t.watch){let e=t.watch;queueMicrotask(()=>Yi(i,e,null))}return{state:i,actions:r}},Qi=([e,t],n)=>{let r=n.split(`.`)[0];return e&&r in e?e:t&&r in t?t:null},$i=(e,t)=>{let n=Li(e),r=null,i=t;for(;i?.getAttribute;){let e=xi(i,Wi);if(e){let t=e.startsWith(`local:`)?i._ps:Gi.get(e);if(t&&(r??=t,Qi(t,n)||t[1]&&n in t[1]))return[t,n]}let t=i._pp?.[0];i=t instanceof Element?t:i.parentElement}if(!n.includes(`.`)){let e=Gi.get(n);if(e)return[e,n]}return[r,n]},ea=(e,t)=>{let n=Li(t),r=Qi(e,n);return r?Ri(r,n):void 0},ta=(e,t,n)=>{let[r,i]=$i(t,e);r&&J(()=>n(r,i))},na=(e,t,n)=>{let[r,i]=Bi(t);ta(e,r[0],(e,t)=>{let a=ea(e,t),o=r.length>=3?Ii(a,r):a;n(i?!o:o)})},ra=(e,t,n)=>{let r=t.split(`.`),i=r.pop(),a=e;for(let e of r)a=a?.[e];a!=null&&(a[i]=n)},ia={enter:`Enter`,space:` `,esc:`Escape`,escape:`Escape`,tab:`Tab`,up:`ArrowUp`,down:`ArrowDown`,left:`ArrowLeft`,right:`ArrowRight`,delete:`Delete`},aa=(e,t)=>{for(let[n,r]of zi(xi(e,t),`:`)){let[t,i]=$i(r,e);if(!t)continue;let[a,o]=t,[s,...c]=n.split(`.`),l=c.includes(`window`)?window:c.includes(`document`)?document:e,u=c.filter(e=>e in ia).map(e=>ia[e]);Ei(l,s,t=>{if(u.length&&!u.includes(t.key))return;c.includes(`prevent`)&&t.preventDefault(),c.includes(`stop`)&&t.stopPropagation();let n=o[i];if(n){n({...e.dataset},{el:e,event:t});return}let r=Ri(o,i);Si(r)||(r=Ri(a,i)),Si(r)&&r()},c.includes(`once`)?{once:!0}:!1)}},oa=(e,t,n)=>{let[r,i]=Vi(t,`->`);if(i!=null){let[t,a]=Vi(i,`~`),o=Hi(t),s=a==null?``:Hi(a);return o==null||s==null?!1:(na(e,r.trim(),e=>n(e?o:s)),!0)}let[a,o]=Vi(t,`~`);if(o==null)return!1;let s=Hi(o);return s==null?!1:(ta(e,a.trim(),(e,t)=>{let r=ea(e,t);n(r==null||r===``?s:r)}),!0)},sa=(e,t)=>{let n=xi(e,t);if(!n)return;let r=t=>{e.textContent=t??``};oa(e,n,r)||ta(e,n,(e,t)=>r(ea(e,t)))},ca=(e,t,n)=>{let r=[],i=0,a=0;for(let o=0;o<=e.length;o++){let s=e[o];o===e.length||i===0&&t.includes(s)&&r.length<n?(r.push(e.slice(a,o)),a=o+1):s===`[`?i++:s===`]`&&i>0&&i--}return r},la=(e,t,n,r)=>{na(e,t,t=>{for(let r of n)e.classList.toggle(r,!!t);for(let n of r)e.classList.toggle(n,!t)})},ua=(e,t)=>{let n=xi(e,t);n&&la(e,n,[],[`hidden`])},da=(e,t)=>{for(let[n,r]of zi(xi(e,t),`->`)){let[t,i=``]=ca(r,`~`,1),a=ca(t,`+ 	
\r`,1/0).filter(Boolean),o=ca(i,`+ 	
\r`,1/0).filter(Boolean);(a.length||o.length)&&la(e,n,a,o)}},fa=(e,t,n)=>{if(t===`value`){e.value=n??``;return}if(t===`checked`){e.checked=!!n;return}if(t.startsWith(`aria-`)&&typeof n==`boolean`){e.setAttribute(t,String(n));return}if(n==null||n===!1){e.removeAttribute(t);return}e.setAttribute(t,n===!0?``:String(n))},pa=(e,t)=>{for(let[n,r]of zi(xi(e,t),`:`)){let t=t=>fa(e,n,t);oa(e,r,t)||na(e,r,t)}},ma=(e,t)=>{for(let[n,r]of zi(xi(e,t),`->`))ta(e,r,(t,r)=>{let i=ea(t,r),a=e.style;i==null||i===!1?a.removeProperty(n):a.setProperty(n,String(i))})},ha=(e,t)=>Ti(e,`value`,t),ga=e=>e.value,_a=[[ha,ga],[ha,ga,!0],[(e,t)=>{e.checked=!!t},e=>e.checked,!0],[(e,t)=>{e.checked=String(t)===e.value},e=>e.checked?e.value:void 0,!0],[()=>{},e=>e.files?[...e.files]:[],!0],[(e,t)=>{let n=Array.isArray(t)?t.map(String):[];for(let t of e.options)t.selected=n.includes(t.value)},e=>Array.from(e.selectedOptions,e=>e.value),!0],[(e,t)=>Ti(e,`textContent`,t),e=>e.textContent]],va=e=>{let t=e.tagName;if(t===`INPUT`){let t=(xi(e,`type`)||``).toLowerCase();return t===`checkbox`?2:t===`radio`?3:t===`file`?4:0}return t===`SELECT`?e.multiple?5:1:xi(e,`contenteditable`)==null?0:6},ya=(e,t)=>{if(typeof e!=`string`)return e;let n=t.has(`trim`)?e.trim():e;if(t.has(`number`)&&n!==``){let e=+n;if(!Number.isNaN(e))return e}return n},ba=(e,t)=>{let n=xi(e,t);if(!n)return;let r=n.split(`|`),[i,a]=$i(r[0],e);if(!i)return;let o=i[0],s=new Set(r.slice(1)),[c,l,u]=_a[va(e)];J(()=>c(e,Ri(o,a))),Ei(e,u||s.has(`lazy`)?`change`:`input`,()=>{let t=l(e);t!==void 0&&ra(o,a,ya(t,s))})},xa=e=>{let t=e;if(t._pb)return null;t._pb=!0;let n=t.content?.firstElementChild;return n?[t,n,t.parentElement]:null},Sa=(e,t,n,r)=>{let i=e.cloneNode(!0);r?.(i);let a=li();return t.insertBefore(i,n.nextSibling),ui(a,()=>Ra(i)),[i,a]},Ca=([e,t])=>{di(t),e.remove()},wa=(e,t)=>{let n=xa(e);if(!n)return;let[r,i,a]=n,o=xi(r,t),s=o.indexOf(` of `);if(s<0)return;let c=o.slice(0,s).trim(),l=xi(r,`data-p-key`)||``,[u,d]=$i(o.slice(s+4).trim(),r);if(!u)return;let f=new Map;fi(()=>{for(let[,e]of f.values())di(e)}),J(()=>{let e=Ri(u[0],d)||[],t=new Set,n=r;e.forEach((e,r)=>{let o=l?Ri({[c]:e},Li(l)):r;t.add(o);let s=f.get(o);if(s){let t=s[0]._ps[0];t[c]!==e&&(t[c]=e),n.nextSibling!==s[0]&&a.insertBefore(s[0],n.nextSibling)}else s=Sa(i,a,n,t=>{t.setAttribute(Wi,Ui+c),t._ps=[Mi({[c]:e}),{}]}),f.set(o,s);n=s[0]});for(let[e,n]of f)t.has(e)||(Ca(n),f.delete(e))})},Ta=(e,t)=>{let n=xa(e);if(!n)return;let[r,i,a]=n,o=null;fi(()=>{o&&di(o[1])}),na(r,xi(r,t),e=>{e&&!o?o=Sa(i,a,r):!e&&o&&(Ca(o),o=null)})},Ea=null,Da=e=>{let t=e;if(!t._pp){let e=!!t.parentNode?.closest?.(`.dark`)&&!t.classList.contains(`dark`);t._pp=[t.parentNode,t.nextSibling,e],t.style.pointerEvents=`auto`,e&&t.classList.add(`dark`),Ea||(Ea=document.createElement(`div`),Ea.id=`publr-portal`,Ea.style.cssText=`position:fixed;top:0;left:0;z-index:9999;pointer-events:none;`,document.body.appendChild(Ea)),Ea.appendChild(t)}return()=>Oa(t)},Oa=e=>{let t=e,n=t._pp;n&&(n[0]&&n[0].insertBefore(t,n[1]||null),t.style.pointerEvents=``,n[2]&&t.classList.remove(`dark`),t._pp=null)},ka=e=>{let t=e;t._pw||(t._pw=!0,fi(Da(t)))},Aa=(e,t)=>{let n=e.querySelectorAll(`[${t}]`);return e.nodeType===1&&xi(e,t)!=null?[e,...n]:n},ja=e=>{for(let t of Aa(e,Wi)){let e=t,n=xi(e,Wi);if(!n)continue;let r=xi(e,`data-p`);if(!n.startsWith(`local:`)){let e=Gi.get(n);e&&Ji(e[0],r);continue}if(e._ps)continue;let i=n.slice(Ui.length),a=Ki.get(i);if(!a)continue;let o=li();e._pc=o,ui(o,()=>{let t=a(),n=Xi(t),[o,s,c,l]=n;if(t?.state&&Yr(Ni(o),i,``),t?.actions&&bi(gi,s,i),Ji(o,r),e._ps=n,c&&Yi(o,c,e),Si(l)){let t=l({el:e});Si(t)&&fi(t)}})}},Ma=e=>{let t=e;for(;t;){let e=t._pc;if(e)return e;t=t.parentElement}return null},Na=e=>{let t=e;t._pc&&(di(t._pc),t._pc=null,t._ps=null,t._pw=!1)},Pa=(e=document)=>{if(!(!e||e.nodeType!==1)){Na(e);for(let t of e.querySelectorAll(`[${Wi}]`))Na(t)}},Fa=null,Ia=()=>{Fa||typeof MutationObserver>`u`||(Fa=new MutationObserver(e=>{for(let t of e)t.removedNodes.forEach(e=>Pa(e))}),Fa.observe(document.documentElement,{childList:!0,subtree:!0}))},La=[[`on`,aa],[`text`,sa],[`show`,ua],[`class`,da],[`bind`,pa],[`style`,ma],[`model`,ba],[`for`,wa],[`if`,Ta],[`portal`,ka]],Ra=(e=document)=>{ja(e);for(let[t,n]of La){let r=`data-p-`+t;for(let t of Aa(e,r)){let e=Ma(t);e?ui(e,()=>n(t,r)):n(t,r)}}return Ia(),e},za={reactive:Mi,effect:J,portal:Da,unportal:Oa,hydrate:Ra,destroy:Pa,randomId(){return globalThis.crypto?.randomUUID?.()??`id-${Math.random().toString(36).slice(2,18)}`},store:Zi,get stores(){let e={};return Gi.forEach((t,n)=>e[n]=t[0]),e},untrack:mi,subscribe:Fi,_internals:[Mi,J,ui,fi,Yr,Ni,Di,Gr,pi,hi,gi,_i,vi,yi]};typeof window<`u`&&(window.Publr=za,document.readyState===`complete`?queueMicrotask(Ra):document.addEventListener(`DOMContentLoaded`,()=>Ra()));function Ba({now:e=Date.now,coalesceMs:t=500,limit:n=100}={}){let r=Mi({canUndo:!1,canRedo:!1,undoDepth:0,redoDepth:0}),i=[],a=[],o=null,s=-1/0;function c(){r.canUndo=i.length>0,r.canRedo=a.length>0,r.undoDepth=i.length,r.redoDepth=a.length}function l(e,t,n){if(!e.length)return null;o=null,t.push(n());let r=e.pop();return c(),r}return{flags:r,record(r,l=null){let u=e(),d=!(l&&l===o&&u-s<t);return d&&(i.push(r()),i.length>n&&i.shift()),o=l,s=u,a.length=0,c(),d},undo:e=>l(i,a,e),redo:e=>l(a,i,e),drop(){let e=i.pop()??null;return o=null,c(),e},reset(){i=[],a=[],o=null,c()}}}var Va={editable:!0,movable:!0,removable:!0,duplicable:!0,stylable:!0,allowedFormats:null},Ha={"content-only":{allowedBlocks:!1,orderable:!1}},Ua={"content-only":{editable:!0,movable:!1,removable:!1,duplicable:!1,stylable:!1}};function Wa(e){let t=e?.toLowerCase().replace(/[\s_]/g,`-`);return t===`fixed`||t===`content-only`||t===`contentonly`?`content-only`:null}var Ga=e=>Wa(e)===`content-only`;function Ka(e){let t=Ha[Wa(e.preset)??``]??{};return{allowedBlocks:e.allowedBlocks??t.allowedBlocks??null,orderable:e.orderable??t.orderable??null,preset:e.preset??null}}function qa(e,t){let n=Ua[Wa(e.preset)??``]??{};return{...Va,...n,...e.blocks?.[t]}}function Ja(e,t){let n=e.slots?.[t];return{allowedBlocks:n?.allowedBlocks??null,orderable:n?.orderable??null}}function Ya(e,t){return e===null?t:t===null?e:e.filter(e=>t.includes(e))}function Xa(e){return`allowed=${e.allowedBlocks===null?`all`:e.allowedBlocks===!1?`none`:e.allowedBlocks.join(`/`)} orderable=${e.orderable??`unset`}${e.preset?` preset=${e.preset}`:``}`}function Za({canvas:e,getBlocks:n,onChange:r,resolveTarget:i}){let a=Mi({blocks:[],active:null}),s=[],c=e=>e&&i?i(e):e,l=[];function u(t){let n=(t instanceof Element?t:t?.parentElement)?.closest(`[data-pb-id]`);return c(n&&e.contains(n)?n.getAttribute(`data-pb-id`):null)}function d(){let e=window.getSelection();if(!e||e.isCollapsed||!e.rangeCount)return[];let t=u(e.anchorNode),r=u(e.focusNode);if(!t||!r||t===r)return[];let i=yt(n(),t,r);return i?i.list.slice(i.lo,i.hi+1).map(e=>e.id):[]}function f(t){if(!(t.length===s.length&&t.every((e,t)=>e===s[t]))){s=t;for(let t of e.querySelectorAll(`.pbe-selected`))t.classList.remove(`pbe-selected`);for(let t of s)e.querySelector(`[data-pb-id="${CSS.escape(t)}"]`)?.classList.add(`pbe-selected`);a.blocks=[...s],r?.(s)}}function p(){let t=d();t.length&&(l=[]),f(t.length?t:[...l]);let n=window.getSelection(),r=null;if(e.contains(document.activeElement)&&n?.rangeCount){let t=t=>{let n=(t instanceof Element?t:t?.parentElement)?.closest(`[data-pb-id]`);return n&&e.contains(n)?n:null},i=t(n.anchorNode);i&&i===t(n.focusNode)&&(r=i.getAttribute(`data-pb-id`))}a.active!==r&&(a.active=r)}function m(){window.getSelection()?.removeAllRanges();let t=document.activeElement;t instanceof HTMLElement&&e.contains(t)&&t.blur()}function h(e){e=c(e),l=[e],m(),f([e])}function g(e){e=c(e);let t=l.length?l:[...s];if(t.includes(e))l=t.filter(t=>t!==e);else{let r=new Set([...t,e]);l=_t(n()).map(e=>e.id).filter(e=>r.has(e))}m(),f([...l])}function _(e){let t=new Set(e.map(e=>c(e)));l=_t(n()).map(e=>e.id).filter(e=>t.has(e)),m(),f([...l])}function v(){l=[],f([])}let y=e=>_t(n()).find(t=>t.id===e)?.type===t,b=e=>!!_t(n()).find(t=>t.id===e)?.children;document.addEventListener(`selectionchange`,p),document.addEventListener(`focusin`,p),document.addEventListener(`focusout`,p);function x(e){e.key===`Escape`&&s.length&&(v(),window.getSelection()?.removeAllRanges())}document.addEventListener(`keydown`,x);function S(e){let t=e.textContent??``;if(!t)return!0;let n=window.getSelection();if(!n?.rangeCount||n.isCollapsed)return!1;let r=n.getRangeAt(0);return!e.contains(r.startContainer)||!e.contains(r.endContainer)?!1:r.toString().length>=t.length}function C(t){if(!(t.metaKey||t.ctrlKey)||t.altKey||t.defaultPrevented||t.key.toLowerCase()!==`a`)return;let r=n();if(!r.length)return;let i=document.activeElement;if(i instanceof HTMLElement&&!e.contains(i)&&(i.matches(`input, textarea, select`)||i.isContentEditable))return;if(s.length){t.preventDefault();let e=gt(r,s[0]);if(!e)return;let n=e.list.map(e=>e.id);if(!n.every(e=>s.includes(e)))return _(n);e.parent&&_(gt(r,e.parent.id).list.map(e=>e.id));return}if(!i||!e.contains(i))return;let a=i.closest(o),c=i.closest(`[data-pb-id]`);a&&c&&!S(a)||(t.preventDefault(),c?h(c.getAttribute(`data-pb-id`)):_(r.map(e=>e.id)))}document.addEventListener(`keydown`,C);let w=null,ee=!1,T=!1;function E(t){let n=t instanceof Element?t.closest(`[data-pb-id]`):null;return c(n&&e.contains(n)?n.getAttribute(`data-pb-id`):null)}function te(t,r){let i=yt(n(),t,r);if(!i)return;let a=e.querySelector(`[data-pb-id="${CSS.escape(i.list[i.lo].id)}"]`),o=e.querySelector(`[data-pb-id="${CSS.escape(i.list[i.hi].id)}"]`);!a||!o||(window.getSelection()?.setBaseAndExtent(a,0,o,o.childNodes.length),p())}function D(t){if(!(t.buttons&1))return ne();if(T){let e=E(document.elementFromPoint(t.clientX,t.clientY));e&&e!==w&&w?te(w,e):e&&e===w&&s.length>1&&h(w);return}if(ee)return;let n=E(document.elementFromPoint(t.clientX,t.clientY));n&&n!==w&&(ee=!0,e.contentEditable=`true`)}function O(t){if(t.button!==0||t.defaultPrevented)return;let r=E(t.target);if(!r)return;if(t.metaKey||t.ctrlKey){t.preventDefault(),g(r);return}if(t.shiftKey){if(t.preventDefault(),l.length===1){let e=l[0];if(vt(n(),r)?.some(t=>t.id===e)){let t=vt(n(),e);h(t[t.length-2]?.id??e);return}}let i=window.getSelection()?.anchorNode,a=i instanceof Element?i:i?.parentElement,o=(a&&e.contains(a)?a.closest(`[data-pb-id]`)?.getAttribute(`data-pb-id`):null)??l[l.length-1];o&&o!==r?te(o,r):h(r);return}let i=t.target instanceof Element&&!!t.target.closest(`[data-pb-text],[data-pb-rich]`);y(r)||b(r)||!i?(t.preventDefault(),T=!0,h(r)):l.length&&v(),w=r,document.addEventListener(`mousemove`,D,!0)}function ne(){document.removeEventListener(`mousemove`,D,!0),w=null,T=!1,ee&&(ee=!1,e.removeAttribute(`contenteditable`),s.length>1&&te(s[0],s[s.length-1]))}function re(e){e.button!==0||e.defaultPrevented||!l.length||E(e.target)||e.target instanceof Element&&e.target.closest(`[data-pbe-keep-selection]`)||v()}return e.addEventListener(`mousedown`,O),document.addEventListener(`mousedown`,re),document.addEventListener(`mouseup`,ne),{state:a,get ids(){return[...s]},active:()=>s.length>0,select:h,selectMany:_,toggle:g,range:te,clear:v,destroy(){document.removeEventListener(`selectionchange`,p),document.removeEventListener(`focusin`,p),document.removeEventListener(`focusout`,p),document.removeEventListener(`keydown`,x),document.removeEventListener(`keydown`,C),document.removeEventListener(`mousedown`,re),document.removeEventListener(`mouseup`,ne),document.removeEventListener(`mousemove`,D,!0),e.removeEventListener(`mousedown`,O)}}}var Qa={name:`classes`,read:(e,t,n=A())=>Ue(t,y(e.classes),n),write(e,t,n,r,i=A()){e.classes=We(t,n,y(e.classes),i).join(` `)}},$a=e=>({to:(t,n)=>N(n,`${e}-${t}`)?`var(--${e}-${t})`:t,from:t=>{let n=RegExp(`^var\\(--${e}-(.+)\\)$`).exec(t.trim());return n?n[1]:t.trim()||void 0}}),Y={to:(e,t)=>/^\d+(\.\d+)?$/.test(e)&&N(t,`spacing`)?`calc(var(--spacing) * ${e})`:/^\d+(\.\d+)?$/.test(e)?`calc(0.25rem * ${e})`:e,from:e=>{let t=/^calc\((?:var\(--spacing\)|0\.25rem) \* (\d+(?:\.\d+)?)\)$/.exec(e.trim());return t?t[1]:e.trim()||void 0}},eo=e=>{let t=Object.fromEntries(Object.entries(e).map(([e,t])=>[t,e]));return{to:t=>e[t]??t,from:e=>t[e.trim()]}},to={fontSize:{property:`font-size`,...$a(`text`)},textAlign:{property:`text-align`,...eo({left:`left`,center:`center`,right:`right`,justify:`justify`})},fontWeight:{property:`font-weight`,...eo({normal:`400`,medium:`500`,semibold:`600`,bold:`700`})},fontStyle:{property:`font-style`,...eo({normal:`normal`,italic:`italic`})},textColor:{property:`color`,...$a(`color`)},backgroundColor:{property:`background-color`,...$a(`color`)},padding:{property:`padding`,...Y},paddingTop:{property:`padding-top`,...Y},paddingRight:{property:`padding-right`,...Y},paddingBottom:{property:`padding-bottom`,...Y},paddingLeft:{property:`padding-left`,...Y},margin:{property:`margin`,...Y},marginTop:{property:`margin-top`,...Y},marginRight:{property:`margin-right`,...Y},marginBottom:{property:`margin-bottom`,...Y},marginLeft:{property:`margin-left`,...Y},width:{property:`width`,...Y},height:{property:`height`,...Y},minHeight:{property:`min-height`,...Y},minWidth:{property:`min-width`,...Y},flexBasis:{property:`flex-basis`,...Y},aspectRatio:{property:`aspect-ratio`,...eo({auto:`auto`,square:`1 / 1`,video:`16 / 9`})},gap:{property:`gap`,...Y},rowGap:{property:`row-gap`,...Y},columnGap:{property:`column-gap`,...Y},justifyContent:{property:`justify-content`,...eo({start:`flex-start`,center:`center`,end:`flex-end`,between:`space-between`,around:`space-around`,evenly:`space-evenly`})},alignItems:{property:`align-items`,...eo({start:`flex-start`,center:`center`,end:`flex-end`,stretch:`stretch`,baseline:`baseline`})},flexWrap:{property:`flex-wrap`,...eo({nowrap:`nowrap`,wrap:`wrap`,reverse:`wrap-reverse`})},gridColumns:{property:`grid-template-columns`,to:e=>/^(?:[1-9]|1[0-2])$/.test(e)?`repeat(${e}, minmax(0, 1fr))`:e,from:e=>{let t=/^repeat\((\d+), minmax\(0, 1fr\)\)$/.exec(e.trim());return t?t[1]:e.trim()||void 0}},borderWidth:{property:`border-width`,to:e=>/^\d+(\.\d+)?$/.test(e)?`${e}px`:e,from:e=>{let t=/^(\d+(?:\.\d+)?)px$/.exec(e.trim());return t?t[1]:e.trim()||void 0}},borderColor:{property:`border-color`,...$a(`color`)},borderRadius:{property:`border-radius`,...$a(`radius`)},borderStyle:{property:`border-style`,...eo({solid:`solid`,dashed:`dashed`,dotted:`dotted`,double:`double`,none:`none`})},lineHeight:{property:`line-height`,...$a(`leading`)},letterSpacing:{property:`letter-spacing`,...$a(`tracking`)},decoration:{property:`text-decoration-line`,...eo({underline:`underline`,strike:`line-through`})},letterCase:{property:`text-transform`,...eo({upper:`uppercase`,lower:`lowercase`,caps:`capitalize`})}};function no(e){return e?e.split(`;`).map(e=>e.trim()).filter(Boolean).map(e=>{let t=e.indexOf(`:`);return t===-1?[e,``]:[e.slice(0,t).trim(),e.slice(t+1).trim()]}):[]}function ro(e,t){let n=t.map(([e,t])=>`${e}: ${t}`).join(`; `);n?e.css=n:delete e.css}var io={name:`inline`,read(e,t,n=A()){let r=to[t];if(!r)return;let i=no(e.css).find(([e])=>e===r.property);return i?r.from(i[1],n):void 0},write(e,t,n,r,i=A()){let a=to[t];if(!a)return;let o=no(e.css).filter(([e])=>e!==a.property);n&&o.push([a.property,a.to(n,i)]);let s=o.some(([e])=>e===`border-width`),c=o.some(([e])=>e===`border-style`);!s&&t===`borderWidth`&&(o=o.filter(([e,t])=>e!==`border-style`||t!==`solid`)),s&&!c&&o.push([`border-style`,`solid`]),ro(e,o)},css(e=A()){return`:root {\n${e.tokens.map(e=>`  --${e.name}: ${e.value};`).join(`
`)}\n}`}};function ao({canvas:e,defaultBlock:t,groupBlock:i,onChange:a,now:s=Date.now,debug:c=!1,placeholder:l=`Type / to choose a block`,policy:u={},theme:d,styleBackend:p=Qa}){let g={blocks:[]};d&&ce(d);let _=/^is-style-(.+)$/;function b(e){for(let t of y(e.classes)){let e=_.exec(t);if(e)return e[1]}return``}function x(e,t){let n=q(e.type),r=new Set(Ne(n?.variations,b(e))),i=y(e.classes).filter(e=>!_.test(e)&&!r.has(e));t&&i.push(`is-style-${t}`,...Ne(n?.variations,t)),e.classes=i.join(` `)}let S=Ka(u);e.hasAttribute(`tabindex`)||(e.tabIndex=-1);function C(){e.contains(document.activeElement)||e.focus({preventScroll:!0})}let w=new Set,ee=()=>queueMicrotask(()=>{a?.();for(let e of w)e()}),T=!!c,E=(...e)=>T&&console.log(`[publr-editor]`,...e),te=()=>`undo ${k.flags.undoDepth} · redo ${k.flags.redoDepth}`,D=Object.keys(u.blocks??{}).length;E(`policy: ${Xa(S)}${D?` · ${D} type-override${D===1?``:`s`}`:``}`);let k=Ba({now:s}),se=()=>({model:structuredClone(g),selection:A()});function A(){let t=document.activeElement,n=t&&e.contains(t)?t.closest(`[data-pb-id]`):null;if(!t||!n)return null;let r={blockId:n.getAttribute(`data-pb-id`)},i=t.closest(o),a=window.getSelection();if(i&&a?.rangeCount&&i.contains(a.getRangeAt(0).startContainer)){let e=a.getRangeAt(0),t=document.createRange();t.selectNodeContents(i),t.setEnd(e.startContainer,e.startOffset),r.field=i.getAttribute(`data-pb-text`)??i.getAttribute(`data-pb-rich`),r.offset=t.toString().length}return r}function j(e){if(!e)return;let t=B(e.blockId);if(!t)return;let n=e.offset!=null&&h(t).find(t=>t.isContentEditable&&(t.getAttribute(`data-pb-text`)===e.field||t.getAttribute(`data-pb-rich`)===e.field));if(!n)return Pe(e.blockId,`end`);n.focus({preventScroll:!0});let r=document.createRange(),i=e.offset,a=!1,o=document.createTreeWalker(n,NodeFilter.SHOW_TEXT);for(let e;e=o.nextNode();){if(i<=e.data.length){r.setStart(e,i),r.collapse(!0),a=!0;break}i-=e.data.length}a||(r.selectNodeContents(n),r.collapse(!1));let s=window.getSelection();s?.removeAllRanges(),s?.addRange(r)}function M(e,t={}){let n=k.record(se,t.key??null);e(g),E(`commit: ${t.label??t.key??`edit`}`,n?`· new entry`:`· coalesced`,`· ${te()}`),ee()}function le(e,t){let n=e(se);if(!n)return E(`${t}: nothing to ${t}`);g=n.model,W(),j(n.selection),E(`${t} → ${g.blocks.length} block${g.blocks.length===1?``:`s`}`,`· ${te()}`),ee()}let N=()=>le(k.undo,`undo`),P=()=>le(k.redo,`redo`),F=!0;e.classList.add(`pbe-patterns-opaque`);let ue=e=>e.type===`pattern`||!!(e.pattern&&Ot(e.pattern)),I=Za({canvas:e,getBlocks:()=>g.blocks,resolveTarget:e=>{if(!F)return e;let t=vt(g.blocks,e);if(!t)return e;let n=t.findIndex(ue);return n===-1?e:(t.slice(n+1).find(Lt)??t[n]).id},onChange:e=>{E(e.length?`select: ${e.length} blocks`:`select: none`),ze()}});function de(t){if(t.button!==0||!F)return;let n=t.target instanceof Element?t.target.closest(`[data-pb-id]`):null,r=n?vt(g.blocks,n.getAttribute(`data-pb-id`)):null;if(!r)return;let i=r.findIndex(ue);if(i===-1||r.slice(i+1).some(Lt))return;let a=r[i];for(let e of document.querySelectorAll(`.pbe-flash-clip`))e.remove();let o=e.getBoundingClientRect(),s=document.createElement(`div`);s.className=`pbe-flash-clip`,s.style.left=`${o.left}px`,s.style.top=`${o.top}px`,s.style.width=`${o.width}px`,s.style.height=`${o.height}px`;for(let t of Rt(a)){let n=e.querySelector(`[data-pb-id="${CSS.escape(t.id)}"]`);if(!n)continue;let r=n.getBoundingClientRect();if(!r.width||!r.height)continue;let i=document.createElement(`div`);i.className=`pbe-flash-veil`,i.style.left=`${r.left-o.left-3}px`,i.style.top=`${r.top-o.top-3}px`,i.style.width=`${r.width+6}px`,i.style.height=`${r.height+6}px`,s.appendChild(i),i.addEventListener(`animationend`,()=>{i.remove(),s.childElementCount||s.remove()},{once:!0})}s.childElementCount&&document.body.appendChild(s)}e.addEventListener(`mousedown`,de);function fe(e){if(e.key!==`Backspace`&&e.key!==`Delete`||e.defaultPrevented||!I.active())return;e.preventDefault();let t=I.ids.filter(ye);if(!t.length)return;let n=L(t[0]),r=n&&n.index>0?n.list[n.index-1]:void 0;M(()=>{for(let e of t)xe(e)},{label:`remove ${t.length} block${t.length===1?``:`s`}`}),W(),window.getSelection()?.removeAllRanges(),r?Pe(r.id,`end`):g.blocks.length&&Pe(g.blocks[0].id,`start`),C()}document.addEventListener(`keydown`,fe,!0);let L=e=>gt(g.blocks,e),R=e=>L(e)?.block,pe=e=>{let t=vt(g.blocks,e)?.find(ue);return t?.pattern?{id:t.id,name:t.pattern}:null},me=e=>{if(!F)return!1;let t=pe(e);return!!t&&t.id!==e},z=e=>{let t=R(e);return!t||!qa(u,t.type).editable?`disabled`:me(e)||Ga(u.preset)?`content-only`:`default`},he=(e,t)=>t.role?t.role:t.transform||(t.field?e?.fields.find(e=>e.name===t.field):void 0)?.type===`tag`?`structure`:t.field?`content`:`advanced`,ge=e=>{let t=qa(u,e.type),n=q(e.type)?.allowedFormats??null,r={...t,allowedFormats:Ya(n,t.allowedFormats)};return me(e.id)?{...r,movable:!1,removable:!1,duplicable:!1,stylable:!1}:r},_e=e=>(e?Ja(u,e.type).orderable:S.orderable)!==!1,ve=e=>{let t=L(e);return!!t&&ge(t.block).movable&&_e(t.parent)},ye=e=>{let t=R(e);return!!t&&ge(t).removable},be=e=>{let t=S.allowedBlocks;return t===null?!0:t!==!1&&t.includes(e)},xe=(e,t)=>{if(!t?.force&&!ye(e))return!1;let n=L(e);return n?(n.list.splice(n.index,1),!0):!1},B=t=>e.querySelector(`[data-pb-id="${CSS.escape(t)}"]`),Se=e=>{let t=e?.closest(`[data-pb-block]`);return t?R(t.getAttribute(`data-pb-id`)??``):void 0},Ce=e=>e instanceof Element?e.closest(o):null;function V(e,r=!0){let i=q(e),a=Object.fromEntries((i?.fields??[]).map(e=>[e.name,n(e.default)])),o={type:e,id:m(),fields:a,classes:``};if(i?.islandSettings.length&&(o.settings={}),i?.acceptsChildren){let e=q(t);o.children=r?i.childTemplate?i.childTemplate.filter(e=>q(e)).map(e=>V(e)):e&&!e.acceptsChildren&&(!i.allowedChildren||i.allowedChildren.includes(t))?[V(t)]:[]:[]}return o}let we=e=>({type:e.type,id:m(),fields:Object.fromEntries(Object.entries(e.fields).map(([e,t])=>[e,n(t)])),...e.classes==null?{}:{classes:e.classes},...e.css==null?{}:{css:e.css},...e.settings==null?{}:{settings:JSON.parse(JSON.stringify(e.settings))},...e.pattern==null?{}:{pattern:e.pattern},...e.children==null?{}:{children:e.children.map(we)}});function Te(e,t){if(!e)return be(t);if(z(e.id)!=="default")return!1;let n=q(e.type)?.allowedChildren;if(n&&!n.includes(t))return!1;let r=Ja(u,e.type).allowedBlocks;return r===null?!0:r!==!1&&r.includes(t)}function Ee(e){let t=Ot(e);if(!t)return null;let n=document.createElement(`div`);n.innerHTML=t.content;let r=ut(n).blocks;for(let e of _t(r))e.id=m();if(!q(`pattern`)?.phantom)return r;for(let e of r)delete e.pattern;return[{type:bt,id:m(),fields:{},classes:``,children:r,pattern:e}]}function H(e,t=`nearest`){let n=[];for(let t=e.parentElement;t;t=t.parentElement)n.push([t,t.scrollLeft]);let r=window.scrollX;e.scrollIntoView({block:t,inline:`nearest`});for(let[e,t]of n)e.scrollLeft!==t&&(e.scrollLeft=t);window.scrollX!==r&&window.scrollTo(r,window.scrollY)}function De(e){if(e.children){let t=B(e.id);t&&H(t),I.select(e.id)}else Pe(e.id,`start`);C()}function U(e){let t=B(e[0].id);t&&H(t),e.length>1?I.range(e[0].id,e[e.length-1].id):I.select(e[0].id),C()}let Oe=e=>!r(e).replace(/<br\s*\/?>/g,``).trim();function ke(e,n){if(n.type===`raw-html`){e.classList.add(`pbe-raw`);return}n.children&&e.classList.add(`pbe-container`);let r=ge(n).editable;for(let t of h(e))if(!r)t.contentEditable=`false`;else if(t.hasAttribute(`data-pb-text`))try{t.contentEditable=`plaintext-only`}catch{t.contentEditable=`true`}else t.hasAttribute(`data-pb-rich`)&&(t.contentEditable=`true`);let i=q(n.type)?.placeholder??(n.type===t?l:null);if(i){let t=h(e).find(e=>e.hasAttribute(`data-pb-text`)||e.hasAttribute(`data-pb-rich`));if(t){let e=t.getAttribute(`data-pb-text`)??t.getAttribute(`data-pb-rich`);t.setAttribute(`data-pbe-ph`,i),t.classList.toggle(`pbe-empty`,Oe(n.fields[e??``]))}}}function Ae(e,t){ke(e,t);for(let n of t.children??[]){let t=e.querySelector(`[data-pb-id="${CSS.escape(n.id)}"]`);t&&Ae(t,n)}}function W(){e.textContent=``;for(let t of g.blocks){let n=dt(t);n&&(Ae(n,t),e.appendChild(n))}I.clear()}function Me(e){let t=R(e),n=B(e);if(!t||!n)return W();let r=A(),i=dt(t);i&&(Ae(i,t),n.classList.contains(`pbe-selected`)&&i.classList.add(`pbe-selected`),n.replaceWith(i),j(r))}function Pe(e,t){let n=B(e),r=n?[...n.matches(`[data-pb-text],[data-pb-rich]`)?[n]:[],...n.querySelectorAll(o)].filter(e=>e.isContentEditable):[],i=t===`start`?r[0]:r[r.length-1];if(!i)return;i.focus({preventScroll:!0});let a=document.createRange();a.selectNodeContents(i),a.collapse(t===`start`);let s=window.getSelection();s?.removeAllRanges(),s?.addRange(a)}e.addEventListener(`keydown`,e=>{let t=e.key.toLowerCase();!(e.metaKey||e.ctrlKey)||t!==`z`&&t!==`y`||(e.preventDefault(),t===`y`||e.shiftKey?P():N())}),e.addEventListener(`beforeinput`,e=>{e.inputType===`historyUndo`?(e.preventDefault(),N()):e.inputType===`historyRedo`&&(e.preventDefault(),P())}),e.addEventListener(`input`,e=>{let t=Ce(e.target),n=t&&Se(t);if(!t||!n||!t.isContentEditable)return;let r=t.hasAttribute(`data-pb-text`)?`text`:`rich`,i=t.getAttribute(`data-pb-${r}`);M(()=>{n.fields[i]=v(t,r)},{key:`field:${n.id}:${i}`,label:`type ${n.id}.${i}`}),t.hasAttribute(`data-pbe-ph`)&&t.classList.toggle(`pbe-empty`,Oe(n.fields[i]))}),e.addEventListener(`keydown`,e=>{let n=q(t);if(e.key!==`Enter`||e.shiftKey||e.defaultPrevented||!n)return;let r=Ce(e.target),i=r&&Se(r);if(!r||!i||!r.isContentEditable)return;let a=r.hasAttribute(`data-pb-text`)?`text`:`rich`,o=r.getAttribute(`data-pb-${a}`),s=q(i.type);if(s?.fields.find(e=>e.name===o)?.preformatted||s?.noSplit?.includes(o))return;let c=L(i.id);if(!c)return;let l=t,u=n;if(!Te(c.parent,t)){if(!Te(c.parent,i.type)||!s)return;l=i.type,u=s}e.preventDefault();let d=v(r,a),p=``,m=window.getSelection();if(m?.rangeCount&&r.contains(m.getRangeAt(0).startContainer)){let e=m.getRangeAt(0),t=t=>{let n=document.createRange();n.selectNodeContents(r),t?n.setEnd(e.startContainer,e.startOffset):n.setStart(e.endContainer,e.endOffset);let i=document.createElement(`div`);return i.appendChild(n.cloneContents()),a===`text`?i.textContent??``:i.innerHTML};d=t(!0),p=t(!1)}let h=V(l),g=u.fields.find(e=>e.type===`rich`||e.type===`text`);g&&(h.fields[g.name]=a===`text`&&g.type===`rich`?f(p):p);let _=L(i.id);_&&(M(()=>{i.fields[o]=d,_.list.splice(_.index+1,0,h)},{label:`split ${i.id} → ${h.id}`}),W(),Pe(h.id,`start`))});let Ie=e=>{let t=document.createElement(`div`);return t.innerHTML=e,t.textContent??``};e.addEventListener(`keydown`,e=>{if(e.key!==`Backspace`||e.defaultPrevented)return;let t=Ce(e.target),n=t&&Se(t);if(!t||!n||!t.isContentEditable)return;let i=window.getSelection();if(!i?.rangeCount||!i.isCollapsed||!t.contains(i.getRangeAt(0).startContainer))return;let a=document.createRange();if(a.selectNodeContents(t),a.setEnd(i.getRangeAt(0).startContainer,i.getRangeAt(0).startOffset),a.toString().length!==0)return;let o=B(n.id);if((o?h(o).filter(e=>e.isContentEditable):[])[0]!==t)return;let s=L(n.id);if(!s)return;let c=s.list[s.index-1];if(!c||!ye(n.id))return;e.preventDefault();let l=t.hasAttribute(`data-pb-text`)?`text`:`rich`,u=t.getAttribute(`data-pb-${l}`),d=r(n.fields[u]);if(!d.replace(/<br\s*\/?>/g,``).trim()){M(()=>{xe(n.id)},{label:`remove ${n.id} (${n.type})`}),W(),Pe(c.id,`end`),C();return}let p=q(c.type)?.fields.filter(e=>e.type===`text`||e.type===`rich`).pop();if(!p){I.select(c.id);return}let m=r(c.fields[p.name]),g=p.type===`text`?m.length:Ie(m).length,_=p.type===`rich`?l===`rich`?d:f(d):l===`rich`?Ie(d):d;M(()=>{c.fields[p.name]=m+_,xe(n.id)},{label:`merge ${n.id} into ${c.id}`}),W(),j({blockId:c.id,field:p.name,offset:g}),C()}),e.addEventListener(`mousedown`,n=>{let r=q(t);if(n.button!==0||!r||n.shiftKey||n.metaKey||n.ctrlKey||n.altKey)return;let i,a=null;if(n.target===e)i=g.blocks;else{let e=n.target instanceof Element?n.target.closest(`[data-pb-id]`):null,t=e?R(e.getAttribute(`data-pb-id`)??``):void 0;if(!t?.children)return;i=t.children,a=t.id}if(!Te(a?R(a)??null:null,t))return;let o=i[i.length-1],s=o&&B(o.id);if(s&&n.clientY<=s.getBoundingClientRect().bottom)return;n.preventDefault();let c=r.fields.filter(e=>e.type===`text`||e.type===`rich`);if(o?.type===t&&c.every(e=>Oe(o.fields[e.name]))){Pe(o.id,`end`);return}if(Le){let e=Le;Le=null,Re(e)}let l=V(t);M(()=>{i.push(l)},{label:`append ${t}${a?` in ${a}`:``}`}),W(),Pe(l.id,`start`),C(),Le=a?{id:l.id,depth:k.flags.undoDepth}:null},!0);let Le=null;function Re(e){let n=L(e.id);if(!n||!n.parent)return;let r=(q(t)?.fields??[]).filter(e=>e.type===`text`||e.type===`rich`);if(n.block.type!==t||!r.every(e=>Oe(n.block.fields[e.name])))return;let i=B(e.id);k.flags.undoDepth===e.depth&&k.flags.redoDepth===0?(k.drop(),xe(e.id,{force:!0}),i?.remove(),E(`ghost ${e.id} abandoned — append canceled · ${te()}`),ee()):(M(()=>{xe(e.id,{force:!0})},{label:`remove abandoned ${e.id}`}),i?.remove())}function ze(){if(!Le||I.state.active===Le.id||I.ids.includes(Le.id))return;let e=Le;Le=null,Re(e)}document.addEventListener(`selectionchange`,ze),document.addEventListener(`focusin`,ze),document.addEventListener(`focusout`,ze);let G=()=>{let e=i?q(i):void 0;return e?.acceptsChildren?e:void 0};function Be(e){let t=e?vt(g.blocks,e):null;if(!t)return null;for(let e=t.length-1;e>=0;e--){if(t[e].pattern)return null;if(t[e].children&&!q(t[e].type)?.phantom)return t[e]}return null}let Ve=e=>!!R(e)?.pattern&&z(e)==="default";function He(e){if(!Ve(e))return!1;let t=L(e);if(!t)return!1;let n=!!q(t.block.type)?.phantom,r=t.block.children??[];return M(()=>{n?t.list.splice(t.index,1,...r):delete t.block.pattern},{label:`convert pattern ${e} to blocks`}),W(),n?r.length?I.selectMany(r.map(e=>e.id)):C():I.select(e),!0}function Ue(e=I.ids){if(!i||!G()||!e.length||e.some(e=>z(e)!=="default"))return null;let t=e.map(e=>L(e)),n=t[0];if(!n||t.some(e=>!e||e.list!==n.list))return E(`group: ids are not siblings — refused`),null;let r=V(i,!1),a=new Set(e),o=Math.min(...t.map(e=>e.index));return M(()=>{let e=[];for(let t=n.list.length-1;t>=0;t--)a.has(n.list[t].id)&&e.unshift(n.list.splice(t,1)[0]);r.children=e,n.list.splice(o,0,r)},{label:`group ${e.length} block${e.length===1?``:`s`} → ${r.id}`}),W(),I.select(r.id),C(),r}function We(e){let t=Be(e??I.ids[0]??I.state.active),n=t&&L(t.id);if(!t||!n||z(t.id)!=="default")return!1;let r=t.children??[],i=A();return M(()=>{n.list.splice(n.index,1,...r)},{label:`ungroup ${t.id} (${r.length} released)`}),W(),i&&i.blockId!==t.id?j(i):r.length&&I.selectMany(r.map(e=>e.id)),C(),!0}function Ge(n){if(n.key!==`Enter`||n.defaultPrevented||!I.active()||n.shiftKey||n.metaKey||n.ctrlKey||n.altKey)return;let r=document.activeElement;if(r instanceof HTMLElement&&!e.contains(r)&&(r.matches(`input, textarea, select, button`)||r.isContentEditable)||!q(t))return;let i=I.ids,a=L(i[i.length-1]);if(!a||!Te(a.parent,t))return;n.preventDefault();let o=V(t);M(()=>{a.list.splice(a.index+1,0,o)},{label:`enter after ${a.block.id} → ${o.id}`}),W(),window.getSelection()?.removeAllRanges(),Pe(o.id,`start`),C()}document.addEventListener(`keydown`,Ge,!0);function Ke(e){if(!(!(e.metaKey||e.ctrlKey)||e.altKey||e.defaultPrevented)&&e.key.toLowerCase()===`g`)if(e.shiftKey){let t=I.ids[0]??I.state.active;if(!t||!Be(t))return;e.preventDefault(),We()}else{if(!G()||!I.active())return;e.preventDefault(),Ue()}}return document.addEventListener(`keydown`,Ke,!0),{history:k.flags,selection:I.state,undo:N,redo:P,canvas:e,defaultBlock:t,subscribe(e){return w.add(e),()=>w.delete(e)},destroy(){document.removeEventListener(`keydown`,fe,!0),document.removeEventListener(`keydown`,Ge,!0),document.removeEventListener(`keydown`,Ke,!0),document.removeEventListener(`selectionchange`,ze),document.removeEventListener(`focusin`,ze),document.removeEventListener(`focusout`,ze),I.destroy()},get debug(){return T},set debug(e){T=!!e},getModel:()=>g,getBlock:e=>R(e),get policy(){return{root:S}},blockPolicy:e=>{let t=R(e);return t?ge(t):Va},editingMode:e=>z(e),patternContext:e=>pe(e),canMove:e=>ve(e),canInsert:e=>be(e),canInsertInto:(e,t)=>Te(e?R(e)??null:null,t),get canInsertAny(){return S.allowedBlocks!==!1},setPolicy(e){u=e,S=Ka(u),W(),ee()},setPatternsOpaque(t){F=t,e.classList.toggle(`pbe-patterns-opaque`,t)},selectBlock(e,t={}){let n=R(e),r=B(e);if(!n||!r)return;if(H(r,t.center?`center`:`nearest`),t.toggle){I.toggle(e);return}if(t.range){let t=I.state.active??I.ids[0];t&&t!==e?I.range(t,e):I.select(e);return}let i=[...r.matches(`[data-pb-text],[data-pb-rich]`)?[r]:[],...r.querySelectorAll(o)].filter(e=>e.isContentEditable);n.children||!i.length?I.select(e):(I.clear(),Pe(e,`start`))},moveBlock(e,t){if(!ve(e))return;let n=L(e);if(!n)return;let r=n.index+t;if(r<0||r>=n.list.length)return;let i=A(),a=I.ids;M(()=>{n.list.splice(r,0,n.list.splice(n.index,1)[0])},{label:`move ${e} ${t>0?`down`:`up`}`}),W(),i?j(i):a.length===1&&a[0]===e&&I.select(e)},format(t){let n=window.getSelection();if(!n?.rangeCount||n.isCollapsed)return;let r=n.getRangeAt(0),i=r.commonAncestorContainer,a=(i instanceof Element?i:i.parentElement)?.closest(`[data-pb-rich]`),o=a&&e.contains(a)&&a.isContentEditable?Se(a):null;if(!a||!o)return;let s=ge(o).allowedFormats;if(s!==null&&!s.includes(t))return;let c=a.getAttribute(`data-pb-rich`),l=ne(a,r,t);if(!l)return;M(()=>{o.fields[c]=l.html},{label:`format ${t} ${o.id}.${c}`}),Me(o.id);let u=B(o.id),d=u&&h(u).find(e=>e.getAttribute(`data-pb-rich`)===c);d&&oe(d,l.start,l.end)},formatState(){let t=window.getSelection();if(!t?.rangeCount)return O(null,null);let n=t.getRangeAt(0),r=n.commonAncestorContainer,i=(r instanceof Element?r:r.parentElement)?.closest(`[data-pb-rich]`);return!i||!e.contains(i)?O(null,null):O(i,n)},applyLink(t,n=``){let r=window.getSelection();if(!r?.rangeCount||r.isCollapsed)return;let i=r.getRangeAt(0),a=i.commonAncestorContainer,o=(a instanceof Element?a:a.parentElement)?.closest(`[data-pb-rich]`),s=o&&e.contains(o)&&o.isContentEditable?Se(o):null;if(!o||!s)return;let c=ge(s).allowedFormats;if(c!==null&&!c.includes(`link`))return;let l=o.getAttribute(`data-pb-rich`),u=t.trim(),d=u?ie(o,i,u,n):ae(o,i);if(!d)return;M(()=>{s.fields[l]=d.html},{label:`${u?`link`:`unlink`} ${s.id}.${l}`}),Me(s.id);let f=B(s.id),p=f&&h(f).find(e=>e.getAttribute(`data-pb-rich`)===l);p&&oe(p,d.start,d.end)},linkState(){let t=window.getSelection();if(!t?.rangeCount)return null;let n=t.getRangeAt(0),r=n.commonAncestorContainer,i=(r instanceof Element?r:r.parentElement)?.closest(`[data-pb-rich]`);return!i||!e.contains(i)?null:re(i,n)},groupBlocks:Ue,ungroupBlock:We,ungroupTarget:e=>Be(e??I.ids[0]??I.state.active)?.id??null,canConvertPattern:Ve,convertPatternToBlocks:He,canDuplicate:e=>{let t=R(e);return!!t&&ge(t).duplicable},duplicateBlock(e){let t=L(e);if(!t||!ge(t.block).duplicable)return null;let n=we(t.block);return M(()=>t.list.splice(t.index+1,0,n),{label:`duplicate ${e}`}),W(),I.select(n.id),n},canRemove:ye,removeBlock(e){let t=L(e);if(!t||!ye(e))return!1;let n=t.list[t.index+1]??t.list[t.index-1];return M(()=>void xe(e),{label:`remove ${e}`}),W(),I.clear(),n?Pe(n.id,`start`):C(),!0},appendChild(e,t){let n=R(e);if(!n?.children||z(e)!=="default"||!q(t)||!Te(n,t))return null;let r=V(t);return M(()=>n.children.push(r),{label:`append ${t} to ${e}`}),W(),I.select(r.id),r},insertBlock(e,t=g.blocks.length){if(!q(e)||!be(e))return null;let n=V(e),r=Math.max(0,Math.min(t,g.blocks.length));return M(()=>{g.blocks.splice(r,0,n)},{label:`insert ${e}`}),W(),De(n),n},insertPattern(e,t=g.blocks.length){let n=Ee(e);if(!n?.length||n.some(e=>!be(e.type)))return null;let r=Math.max(0,Math.min(t,g.blocks.length));return M(()=>{g.blocks.splice(r,0,...n)},{label:`insert pattern ${e}`}),W(),U(n),n},replaceWithPattern(e,t){let n=L(e),r=n&&Ee(t);return!r?.length||r.some(e=>!Te(n.parent,e.type))?null:(M(()=>{n.list.splice(n.index,1,...r)},{label:`replace ${e} with pattern ${t}`}),W(),U(r),r)},setBlockChildren(e,t){let n=R(e);if(!n||!n.children)return null;let r=document.createElement(`div`);r.innerHTML=t;let i=ut(r).blocks;M(()=>{n.children=i},{label:`set children of ${e} (${i.length} blocks)`}),W();let a=B(e);return a&&H(a),I.select(e),C(),n},setField(e,t,r){let i=R(e),a=i&&q(i.type),o=a?.fields.find(e=>e.name===t),s=z(e);!a||!o||s===`disabled`||s===`content-only`&&o.type===`tag`||JSON.stringify(i.fields[t])!==JSON.stringify(r)&&(M(()=>{i.fields[t]=n(r)},{label:`set ${e}.${t}`}),Me(e))},setSetting(e,t,n){let r=R(e),i=r&&q(r.type),a=i?.islandSettings.find(e=>e.name===t),o=i?.settings?.find(e=>e.setting===t)?.role??`advanced`,s=z(e),c=JSON.stringify(n);if(!r||!a||c===void 0||s===`disabled`||s===`content-only`&&o!==`content`)return;let l=r.settings&&t in r.settings?r.settings[t]:a.default;c!==JSON.stringify(l)&&(M(()=>{r.settings??={},c===JSON.stringify(a.default)?delete r.settings[t]:r.settings[t]=JSON.parse(c)},{label:`set ${e}.${t} = ${c}`}),Me(e))},resetSettings(e,t){let r=R(e),i=r&&q(r.type),a=z(e);if(!r||!i||a===`disabled`||a===`content-only`&&t!==`content`)return!1;let o=(i.settings??[]).filter(e=>!e.transform&&he(i,e)===t).filter(e=>{if(e.setting)return!!r.settings&&e.setting in r.settings;let t=i.fields.find(t=>t.name===e.field);return!!t&&JSON.stringify(r.fields[t.name])!==JSON.stringify(t.default)});return o.length?(M(()=>{for(let e of o)if(e.setting)delete r.settings?.[e.setting];else{let t=i.fields.find(t=>t.name===e.field);r.fields[t.name]=n(t.default)}},{label:`reset ${t} settings ${e}`}),Me(e),!0):!1},setStyles(e,t){let n=R(e);if(!n||!ge(n).stylable)return!1;let r=q(n.type),i=Object.entries(t).filter(([e,t])=>{let i=e===`variation`?!!r?.variations?.length:Fe(r?.supports,e),a=e===`variation`?b(n):p.read(n,e)??``;return i&&a!==t});return i.length?(M(()=>{for(let[e,t]of i)e===`variation`?x(n,t):p.write(n,e,t,`element`)},{label:`style ${e}: ${i.map(([e])=>e).join(`, `)}`}),Me(e),!0):!1},setStyle(e,t,n){let r=R(e);if(!r||!ge(r).stylable)return;let i=q(r.type);(t===`variation`?i?.variations?.length:Fe(i?.supports,t))&&(t===`variation`?b(r):p.read(r,t)??``)!==n&&(M(()=>{t===`variation`?x(r,n):p.write(r,t,n,`element`)},{label:`style ${e}.${t} = ${n||`(cleared)`}`}),Me(e))},resetStyles(e){let t=R(e);if(!t||!ge(t).stylable)return!1;let n=q(t.type),r=Object.keys(je).filter(e=>Fe(n?.supports,e)&&!!p.read(t,e)),i=n?.variations?.length?b(t):``;return!r.length&&!i?!1:(M(()=>{for(let e of r)p.write(t,e,``,`element`);i&&x(t,``)},{label:`reset styles ${e}`}),Me(e),!0)},resetStylePanel(e,t){let n=R(e);if(!n||!ge(n).stylable)return!1;let r=q(n.type),i=t.split(`,`).map(e=>e.trim()),a=Object.entries(je).filter(([e,t])=>i.includes(t.panel)&&Fe(r?.supports,e)&&!!p.read(n,e)).map(([e])=>e),o=i.includes(`styles`)&&r?.variations?.length?b(n):``;return!a.length&&!o?!1:(M(()=>{for(let e of a)p.write(n,e,``,`element`);o&&x(n,``)},{label:`reset ${t} styles ${e}`}),Me(e),!0)},styleSupports:e=>q(R(e)?.type??``)?.supports,blockVariations:e=>q(R(e)?.type??``)?.variations,canStyle:e=>{let t=R(e);return!!t&&ge(t).stylable},getStyle:(e,t)=>{let n=R(e);return n?t===`variation`?b(n):p.read(n,t)??``:``},styleBackend:()=>p,setTheme(e){ce(e),W()},transformBlock(e,t){if(z(e)!=="default")return null;let r=L(e),i=q(t);if(!r||!i||r.block.type===t||r.block.type===`raw-html`||!Te(r.parent,t))return null;let a=r.block;if(a.children?.length&&!i.acceptsChildren)return null;let o={type:t,id:e,fields:{},classes:a.classes??``};for(let e of i.fields)o.fields[e.name]=n(a.fields[e.name]??e.default);if(i.acceptsChildren&&(o.children=a.children??[]),i.islandSettings.length){o.settings={};for(let e of i.islandSettings)a.settings&&e.name in a.settings&&(o.settings[e.name]=a.settings[e.name])}return M(()=>{r.list.splice(r.index,1,o)},{label:`transform ${e} → ${t}`}),Me(e),o},replaceBlock(e,t){if(z(e)!=="default")return null;let n=L(e);if(!n||!q(t)||!Te(n.parent,t))return null;let r=V(t);return M(()=>{n.list.splice(n.index,1,r)},{label:`transform ${e} → ${t}`}),W(),De(r),r},setClasses(e,t){let n=R(e);!n||z(e)!=="default"||(M(()=>{n.classes=t??``},{label:`classes ${e}`}),Me(e))},loadHtml(e){let t=document.createElement(`div`);t.innerHTML=e,g=ut(t.querySelector(`[data-pb-doc]`)??t),k.reset(),Le=null,W(),E(`load: ${g.blocks.length} blocks · history reset`),ee()},serialize:e=>ht(g,e?.pipeline)}}var oo=`0 0 24 24`,so={accordion:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="3.75" width="17" height="4.25" rx="1"/><rect x="3.5" y="10.5" width="17" height="9.75" rx="1"/><path d="M12 13.25v4.25"/><path d="M9.875 15.375h4.25"/></g>`,"alert-hexagon":`<path d="M12 8.00008V12.0001M12 16.0001H12.01M3 7.94153V16.0586C3 16.4013 3 16.5726 3.05048 16.7254C3.09515 16.8606 3.16816 16.9847 3.26463 17.0893C3.37369 17.2077 3.52345 17.2909 3.82297 17.4573L11.223 21.5684C11.5066 21.726 11.6484 21.8047 11.7985 21.8356C11.9315 21.863 12.0685 21.863 12.2015 21.8356C12.3516 21.8047 12.4934 21.726 12.777 21.5684L20.177 17.4573C20.4766 17.2909 20.6263 17.2077 20.7354 17.0893C20.8318 16.9847 20.9049 16.8606 20.9495 16.7254C21 16.5726 21 16.4013 21 16.0586V7.94153C21 7.59889 21 7.42756 20.9495 7.27477C20.9049 7.13959 20.8318 7.01551 20.7354 6.91082C20.6263 6.79248 20.4766 6.70928 20.177 6.54288L12.777 2.43177C12.4934 2.27421 12.3516 2.19543 12.2015 2.16454C12.0685 2.13721 11.9315 2.13721 11.7985 2.16454C11.6484 2.19543 11.5066 2.27421 11.223 2.43177L3.82297 6.54288C3.52345 6.70928 3.37369 6.79248 3.26463 6.91082C3.16816 7.01551 3.09515 7.13959 3.05048 7.27477C3 7.42756 3 7.59889 3 7.94153Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,"alert-triangle":`<path d="M11.9998 8.99999V13M11.9998 17H12.0098M10.6151 3.89171L2.39019 18.0983C1.93398 18.8863 1.70588 19.2803 1.73959 19.6037C1.769 19.8857 1.91677 20.142 2.14613 20.3088C2.40908 20.5 2.86435 20.5 3.77487 20.5H20.2246C21.1352 20.5 21.5904 20.5 21.8534 20.3088C22.0827 20.142 22.2305 19.8857 22.2599 19.6037C22.2936 19.2803 22.0655 18.8863 21.6093 18.0983L13.3844 3.89171C12.9299 3.10654 12.7026 2.71396 12.4061 2.58211C12.1474 2.4671 11.8521 2.4671 11.5935 2.58211C11.2969 2.71396 11.0696 3.10655 10.6151 3.89171Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,"arrow-left":`<path d="M19 12H5M5 12L12 19M5 12L12 5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,audio:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="7.4" cy="17" r="2.3" fill="currentColor" stroke="none"/><path d="M9.7 17V6.5"/><path d="M9.7 6.5c3 .5 4.9 2 5.4 4.5"/></g>`,bold:`<g fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round"><path d="M8 5h5a3.5 3.5 0 0 1 0 7H8z"/><path d="M8 12h6a3.5 3.5 0 0 1 0 7H8z"/></g>`,bookmark:`<path d="M5 7.8C5 6.11984 5 5.27976 5.32698 4.63803C5.6146 4.07354 6.07354 3.6146 6.63803 3.32698C7.27976 3 8.11984 3 9.8 3H14.2C15.8802 3 16.7202 3 17.362 3.32698C17.9265 3.6146 18.3854 4.07354 18.673 4.63803C19 5.27976 19 6.11984 19 7.8V21L12 17L5 21V7.8Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,button:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="8" width="17" height="8" rx="2.5"/><path d="M8 12h8"/></g>`,buttons:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4.5" width="17" height="6.5" rx="2"/><rect x="3.5" y="13" width="17" height="6.5" rx="2"/><path d="M8 7.75h8"/><path d="M8 16.25h8"/></g>`,"calendar-check-02":`<path d="M21 10H3M21 12.5V8.8C21 7.11984 21 6.27976 20.673 5.63803C20.3854 5.07354 19.9265 4.6146 19.362 4.32698C18.7202 4 17.8802 4 16.2 4H7.8C6.11984 4 5.27976 4 4.63803 4.32698C4.07354 4.6146 3.6146 5.07354 3.32698 5.63803C3 6.27976 3 7.11984 3 8.8V17.2C3 18.8802 3 19.7202 3.32698 20.362C3.6146 20.9265 4.07354 21.3854 4.63803 21.673C5.27976 22 6.11984 22 7.8 22H12M16 2V6M8 2V6M14.5 19L16.5 21L21 16.5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,"calendar-check":`<path d="M21 10H3M16 2V6M8 2V6M9 16L11 18L15 14M7.8 22H16.2C17.8802 22 18.7202 22 19.362 21.673C19.9265 21.3854 20.3854 20.9265 20.673 20.362C21 19.7202 21 18.8802 21 17.2V8.8C21 7.11984 21 6.27976 20.673 5.63803C20.3854 5.07354 19.9265 4.6146 19.362 4.32698C18.7202 4 17.8802 4 16.2 4H7.8C6.11984 4 5.27976 4 4.63803 4.32698C4.07354 4.6146 3.6146 5.07354 3.32698 5.63803C3 6.27976 3 7.11984 3 8.8V17.2C3 18.8802 3 19.7202 3.32698 20.362C3.6146 20.9265 4.07354 21.3854 4.63803 21.673C5.27976 22 6.11984 22 7.8 22Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,caption:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="5" width="17" height="14" rx="2"/><path d="M7 15.5h10"/></g>`,chart:`<path d="M21 21H4.6C4.03995 21 3.75992 21 3.54601 20.891C3.35785 20.7951 3.20487 20.6422 3.10899 20.454C3 20.2401 3 19.9601 3 19.4V3M21 7L15.5657 12.4343C15.3677 12.6323 15.2687 12.7313 15.1545 12.7684C15.0541 12.8011 14.9459 12.8011 14.8455 12.7684C14.7313 12.7313 14.6323 12.6323 14.4343 12.4343L12.5657 10.5657C12.3677 10.3677 12.2687 10.2687 12.1545 10.2316C12.0541 10.1989 11.9459 10.1989 11.8455 10.2316C11.7313 10.2687 11.6323 10.3677 11.4343 10.5657L7 15M21 7H17M21 7V11" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,check:`<path d="M20 6L9 17L4 12" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,"chevron-down":`<path d="M6 9L12 15L18 9" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,"chevron-left":`<path d="M15 18L9 12L15 6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,"chevron-right":`<path d="M9 18L15 12L9 6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,"chevron-up":`<path d="M18 15L12 9L6 15" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,"clock-check":`<path d="M14.5 19L16.5 21L21 16.5M21.9851 12.5499C21.995 12.3678 22 12.1845 22 12C22 6.47715 17.5228 2 12 2C6.47715 2 2 6.47715 2 12C2 17.4354 6.33651 21.858 11.7385 21.9966M12 6V12L15.7384 13.8692" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,"clock-rewind":`<path d="M22.7 13.5L20.7005 11.5L18.7 13.5M21 12C21 16.9706 16.9706 21 12 21C7.02944 21 3 16.9706 3 12C3 7.02944 7.02944 3 12 3C15.3019 3 18.1885 4.77814 19.7545 7.42909M12 7V12L15 14" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,close:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6 6l12 12"/><path d="M18 6L6 18"/></g>`,code:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M8 8l-4 4 4 4"/><path d="M16 8l4 4-4 4"/><path d="M13.5 5.5l-3 13"/></g>`,column:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="8.5" y="4.5" width="7" height="15" rx="1.5"/><path d="M4.5 6.5v11"/><path d="M19.5 6.5v11"/></g>`,columns:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4.5" width="17" height="15" rx="2"/><path d="M9.5 4.5v15"/><path d="M14.5 4.5v15"/></g>`,components:`<path d="M15.0505 9H5.5C4.11929 9 3 7.88071 3 6.5C3 5.11929 4.11929 4 5.5 4H15.0505M8.94949 20H18.5C19.8807 20 21 18.8807 21 17.5C21 16.1193 19.8807 15 18.5 15H8.94949M3 17.5C3 19.433 4.567 21 6.5 21C8.433 21 10 19.433 10 17.5C10 15.567 8.433 14 6.5 14C4.567 14 3 15.567 3 17.5ZM21 6.5C21 8.433 19.433 10 17.5 10C15.567 10 14 8.433 14 6.5C14 4.567 15.567 3 17.5 3C19.433 3 21 4.567 21 6.5Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,copy:`<path d="M7.5 3H14.6C16.8402 3 17.9603 3 18.816 3.43597C19.5686 3.81947 20.1805 4.43139 20.564 5.18404C21 6.03969 21 7.15979 21 9.4V16.5M6.2 21H14.3C15.4201 21 15.9802 21 16.408 20.782C16.7843 20.5903 17.0903 20.2843 17.282 19.908C17.5 19.4802 17.5 18.9201 17.5 17.8V9.7C17.5 8.57989 17.5 8.01984 17.282 7.59202C17.0903 7.21569 16.7843 6.90973 16.408 6.71799C15.9802 6.5 15.4201 6.5 14.3 6.5H6.2C5.0799 6.5 4.51984 6.5 4.09202 6.71799C3.71569 6.90973 3.40973 7.21569 3.21799 7.59202C3 8.01984 3 8.57989 3 9.7V17.8C3 18.9201 3 19.4802 3.21799 19.908C3.40973 20.2843 3.71569 20.5903 4.09202 20.782C4.51984 21 5.0799 21 6.2 21Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,cover:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="3.5" width="17" height="17" rx="2"/><circle cx="8.5" cy="8.25" r="1.4"/><path d="M7 14.75h10"/><path d="M9 17.75h6"/></g>`,decorative:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12c1.9-3.4 4.6-5.25 8-5.25S18.1 8.6 20 12c-1.9 3.4-4.6 5.25-8 5.25S5.9 15.4 4 12z"/><circle cx="12" cy="12" r="2.25"/><path d="M5.75 18.25L18.25 5.75"/></g>`,details:`<path d="M5 5l4.25 2.6L5 10.2z" fill="currentColor" stroke="none"/><g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12.5 7.5H20"/><path d="M4 13h16"/><path d="M4 17.5h16"/></g>`,"dot-filled":`<circle cx="12" cy="12" r="6" fill="currentColor"/>`,"dot-half":`<circle cx="12" cy="12" r="5" stroke="currentColor" stroke-width="2"/>
<path d="M12 7a5 5 0 010 10V7z" fill="currentColor"/>`,"dot-outline":`<circle cx="12" cy="12" r="5" stroke="currentColor" stroke-width="2"/>`,duplicate:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="8.75" y="8.75" width="11.25" height="11.25" rx="2"/><path d="M15.25 5.25V5a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v7.25a2 2 0 0 0 2 2h.25"/></g>`,edit:`<path d="M2.87601 18.1156C2.92195 17.7021 2.94493 17.4954 3.00748 17.3022C3.06298 17.1307 3.1414 16.9676 3.24061 16.8171C3.35242 16.6475 3.49952 16.5005 3.7937 16.2063L17 3C18.1046 1.89543 19.8954 1.89543 21 3C22.1046 4.10457 22.1046 5.89543 21 7L7.7937 20.2063C7.49951 20.5005 7.35242 20.6475 7.18286 20.7594C7.03242 20.8586 6.86926 20.937 6.69782 20.9925C6.50457 21.055 6.29783 21.078 5.88434 21.124L2.49997 21.5L2.87601 18.1156Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,external:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M11 5H7a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-4"/><path d="M13.75 4.5h5.75v5.75"/><path d="M19.5 4.5L11.75 12.25"/></g>`,file:`<path d="M14 2.26946V6.4C14 6.96005 14 7.24008 14.109 7.45399C14.2049 7.64215 14.3578 7.79513 14.546 7.89101C14.7599 8 15.0399 8 15.6 8H19.7305M20 9.98822V17.2C20 18.8802 20 19.7202 19.673 20.362C19.3854 20.9265 18.9265 21.3854 18.362 21.673C17.7202 22 16.8802 22 15.2 22H8.8C7.11984 22 6.27976 22 5.63803 21.673C5.07354 21.3854 4.6146 20.9265 4.32698 20.362C4 19.7202 4 18.8802 4 17.2V6.8C4 5.11984 4 4.27976 4.32698 3.63803C4.6146 3.07354 5.07354 2.6146 5.63803 2.32698C6.27976 2 7.11984 2 8.8 2H12.0118C12.7455 2 13.1124 2 13.4577 2.08289C13.7638 2.15638 14.0564 2.27759 14.3249 2.44208C14.6276 2.6276 14.887 2.88703 15.4059 3.40589L18.5941 6.59411C19.113 7.11297 19.3724 7.3724 19.5579 7.67515C19.7224 7.94356 19.8436 8.2362 19.9171 8.5423C20 8.88757 20 9.25445 20 9.98822Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,"folder-plus":`<path d="M13 7L11.8845 4.76892C11.5634 4.1268 11.4029 3.80573 11.1634 3.57116C10.9516 3.36373 10.6963 3.20597 10.4161 3.10931C10.0992 3 9.74021 3 9.02229 3H5.2C4.0799 3 3.51984 3 3.09202 3.21799C2.71569 3.40973 2.40973 3.71569 2.21799 4.09202C2 4.51984 2 5.0799 2 6.2V7M2 7H17.2C18.8802 7 19.7202 7 20.362 7.32698C20.9265 7.6146 21.3854 8.07354 21.673 8.63803C22 9.27976 22 10.1198 22 11.8V16.2C22 17.8802 22 18.7202 21.673 19.362C21.3854 19.9265 20.9265 20.3854 20.362 20.673C19.7202 21 18.8802 21 17.2 21H6.8C5.11984 21 4.27976 21 3.63803 20.673C3.07354 20.3854 2.6146 19.9265 2.32698 19.362C2 18.7202 2 17.8802 2 16.2V7ZM12 17V11M9 14H15" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,folder:`<path d="M13 7L11.8845 4.76892C11.5634 4.1268 11.4029 3.80573 11.1634 3.57116C10.9516 3.36373 10.6963 3.20597 10.4161 3.10931C10.0992 3 9.74021 3 9.02229 3H5.2C4.0799 3 3.51984 3 3.09202 3.21799C2.71569 3.40973 2.40973 3.71569 2.21799 4.09202C2 4.51984 2 5.0799 2 6.2V7M2 7H17.2C18.8802 7 19.7202 7 20.362 7.32698C20.9265 7.6146 21.3854 8.07354 21.673 8.63803C22 9.27976 22 10.1198 22 11.8V16.2C22 17.8802 22 18.7202 21.673 19.362C21.3854 19.9265 20.9265 20.3854 20.362 20.673C19.7202 21 18.8802 21 17.2 21H6.8C5.11984 21 4.27976 21 3.63803 20.673C3.07354 20.3854 2.6146 19.9265 2.32698 19.362C2 18.7202 2 17.8802 2 16.2V7Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,gallery:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7 6V5.5a2 2 0 0 1 2-2h9.5a2 2 0 0 1 2 2V15a2 2 0 0 1-2 2H18"/><rect x="3.5" y="7" width="14" height="13.5" rx="2"/><path d="M3.5 16.75l3.5-3 3 2.5 2.75-2.25 4.75 3.75"/></g>`,globe:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17"/><path d="M12 3.5c-3 2.4-4.5 5.4-4.5 8.5s1.5 6.1 4.5 8.5c3-2.4 4.5-5.4 4.5-8.5S15 5.9 12 3.5z"/></g>`,grid:`<path d="M3 3H10V10H3V3ZM14 3H21V10H14V3ZM14 14H21V21H14V14ZM3 14H10V21H3V14Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,"group-blocks":`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.75" y="3.75" width="16.5" height="16.5" rx="2" stroke-dasharray="3.1 2.6"/><rect x="7.25" y="7.25" width="4.25" height="9.5" rx="1"/><rect x="14" y="7.25" width="2.75" height="9.5" rx="1"/></g>`,group:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="11" height="11" rx="2"/><path d="M9 20h9a2 2 0 0 0 2-2V9"/></g>`,"heading-level-1":`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5v11"/><path d="M10.5 6.5v11"/><path d="M4 12h6.5"/><path d="M15.5 8.25l2.25-1.75v11"/></g>`,"heading-level-2":`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5v11"/><path d="M10.5 6.5v11"/><path d="M4 12h6.5"/><path d="M14.5 9.25c.2-1.6 1.5-2.75 3-2.75 1.65 0 2.9 1.2 2.9 2.8 0 1-.5 1.85-1.45 2.8l-4.45 5.4h6"/></g>`,"heading-level-3":`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5v11"/><path d="M10.5 6.5v11"/><path d="M4 12h6.5"/><path d="M14.75 8c.6-.95 1.65-1.5 2.9-1.5 1.7 0 2.95 1 2.95 2.5 0 1.35-1 2.25-2.4 2.5 1.5.2 2.7 1.1 2.7 2.7 0 1.7-1.45 2.8-3.25 2.8-1.35 0-2.45-.55-3.1-1.5"/></g>`,"heading-level-4":`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5v11"/><path d="M10.5 6.5v11"/><path d="M4 12h6.5"/><path d="M18.75 6.5l-4.25 7.25h6.25"/><path d="M18.75 6.5v11"/></g>`,"heading-level-5":`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5v11"/><path d="M10.5 6.5v11"/><path d="M4 12h6.5"/><path d="M20 6.5h-4.75l-.5 5c.6-.55 1.4-.85 2.3-.85 1.9 0 3.2 1.35 3.2 3.25s-1.45 3.35-3.35 3.35c-1.3 0-2.4-.6-3-1.55"/></g>`,"heading-level-6":`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5v11"/><path d="M10.5 6.5v11"/><path d="M4 12h6.5"/><path d="M19.9 7.1c-.55-.45-1.25-.7-2.05-.7-2.2 0-3.6 1.85-3.6 4.6v2.9c0 2.05 1.45 3.5 3.3 3.5s3.3-1.45 3.3-3.3-1.45-3.3-3.3-3.3c-1.55 0-2.85 1-3.3 2.4"/></g>`,heading:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7 4.5h10V19.5l-5-4.1-5 4.1z"/></g>`,home:`<path d="M3 10.5651C3 9.9907 3 9.70352 3.07403 9.43905C3.1396 9.20478 3.24737 8.98444 3.39203 8.78886C3.55534 8.56806 3.78202 8.39175 4.23539 8.03912L11.0177 2.764C11.369 2.49075 11.5447 2.35412 11.7387 2.3016C11.9098 2.25526 12.0902 2.25526 12.2613 2.3016C12.4553 2.35412 12.631 2.49075 12.9823 2.764L19.7646 8.03913C20.218 8.39175 20.4447 8.56806 20.608 8.78886C20.7526 8.98444 20.8604 9.20478 20.926 9.43905C21 9.70352 21 9.9907 21 10.5651V17.8C21 18.9201 21 19.4801 20.782 19.908C20.5903 20.2843 20.2843 20.5903 19.908 20.782C19.4802 21 18.9201 21 17.8 21H6.2C5.07989 21 4.51984 21 4.09202 20.782C3.71569 20.5903 3.40973 20.2843 3.21799 19.908C3 19.4801 3 18.9201 3 17.8V10.5651Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,html:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4" width="17" height="16" rx="2"/><path d="M10 9.5L7.5 12l2.5 2.5"/><path d="M14 9.5l2.5 2.5L14 14.5"/></g>`,icon:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="7.25" cy="7.25" r="3.75"/><path d="M13.75 4.5l5.75 5.75"/><path d="M19.5 4.5l-5.75 5.75"/><path d="M3.5 19.75l3.75-6.5 3.75 6.5z"/><rect x="13.5" y="13.25" width="6.5" height="6.5" rx="1.5"/></g>`,image:`<path d="M4 16L8.58579 11.4142C9.36683 10.6332 10.6332 10.6332 11.4142 11.4142L16 16M14 14L15.5858 12.4142C16.3668 11.6332 17.6332 11.6332 18.4142 12.4142L20 14M14 8H14.01M6 20H18C19.1046 20 20 19.1046 20 18V6C20 4.89543 19.1046 4 18 4H6C4.89543 4 4 4.89543 4 6V18C4 19.1046 4.89543 20 6 20Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,italic:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10.5 5h6.5"/><path d="M7 19h6.5"/><path d="M13.75 5l-4 14"/></g>`,link:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M13.75 10.25a3.5 3.5 0 0 1 0 4.95l-2.55 2.55a3.5 3.5 0 0 1-4.95-4.95l1.3-1.3"/><path d="M10.25 13.75a3.5 3.5 0 0 1 0-4.95l2.55-2.55a3.5 3.5 0 0 1 4.95 4.95l-1.3 1.3"/></g>`,"list-item":`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="12" r="1.4" fill="currentColor" stroke="none"/><path d="M10.5 12h9.5"/></g>`,"list-ordered":`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 6.25L6 5.25v5"/><path d="M4.5 14.75c.15-1 .95-1.6 1.85-1.5.85.1 1.5.8 1.4 1.65-.05.55-.45 1-.95 1.5L4.5 18.75h3.6"/><path d="M11 7.75h9"/><path d="M11 16.25h9"/></g>`,"list-unordered":`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="5.5" cy="8" r="1.4" fill="currentColor" stroke="none"/><circle cx="5.5" cy="16" r="1.4" fill="currentColor" stroke="none"/><path d="M10.5 8H20"/><path d="M10.5 16H20"/></g>`,"list-view":`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5h9.5"/><path d="M10.5 12h9.5"/><path d="M4 17.5h9.5"/></g>`,list:`<path d="M21 12L9 12M21 6L9 6M21 18L9 18M5 12C5 12.5523 4.55228 13 4 13C3.44772 13 3 12.5523 3 12C3 11.4477 3.44772 11 4 11C4.55228 11 5 11.4477 5 12ZM5 6C5 6.55228 4.55228 7 4 7C3.44772 7 3 6.55228 3 6C3 5.44772 3.44772 5 4 5C4.55228 5 5 5.44772 5 6ZM5 18C5 18.5523 4.55228 19 4 19C3.44772 19 3 18.5523 3 18C3 17.4477 3.44772 17 4 17C4.55228 17 5 17.4477 5 18Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,lock:`<path d="M17 11V8C17 5.23858 14.7614 3 12 3C9.23858 3 7 5.23858 7 8V11M12 14.5V16.5M9.8 21H14.2C15.8802 21 16.7202 21 17.362 20.673C17.9265 20.3854 18.3854 19.9265 18.673 19.362C19 18.7202 19 17.8802 19 16.2V15.8C19 14.1198 19 13.2798 18.673 12.638C18.3854 12.0735 17.9265 11.6146 17.362 11.327C16.7202 11 15.8802 11 14.2 11H9.8C8.11984 11 7.27976 11 6.63803 11.327C6.07354 11.6146 5.6146 12.0735 5.32698 12.638C5 13.2798 5 14.1198 5 15.8V16.2C5 17.8802 5 18.7202 5.32698 19.362C5.6146 19.9265 6.07354 20.3854 6.63803 20.673C7.27976 21 8.11984 21 9.8 21Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,logout:`<path d="M16 17L21 12M21 12L16 7M21 12H9M9 3H7.8C6.11984 3 5.27976 3 4.63803 3.32698C4.07354 3.6146 3.6146 4.07354 3.32698 4.63803C3 5.27976 3 6.11984 3 7.8V16.2C3 17.8802 3 18.7202 3.32698 19.362C3.6146 19.9265 4.07354 20.3854 4.63803 20.673C5.27976 21 6.11984 21 7.8 21H9" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,math:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7.25 4.75v5"/><path d="M4.75 7.25h5"/><path d="M14.25 7.25h5"/><path d="M5.5 14.5l3.5 3.5"/><path d="M9 14.5l-3.5 3.5"/><path d="M14.25 16.5h5"/><circle cx="16.75" cy="13.9" r="1" fill="currentColor" stroke="none"/><circle cx="16.75" cy="19.1" r="1" fill="currentColor" stroke="none"/></g>`,"media-text":`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="7" width="8" height="10" rx="1.5"/><path d="M14.75 9h5.75"/><path d="M14.75 12h5.75"/><path d="M14.75 15h5.75"/></g>`,"menu-03":`<path d="M3 12H21M3 6H21M3 18H15" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,moon:`<path d="M21.9548 12.9564C20.5779 15.3717 17.9791 17.0001 15 17.0001C10.5817 17.0001 7 13.4184 7 9.00008C7 6.02072 8.62867 3.42175 11.0443 2.04492C5.96975 2.52607 2 6.79936 2 11.9998C2 17.5227 6.47715 21.9998 12 21.9998C17.2002 21.9998 21.4733 18.0305 21.9548 12.9564Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,more:`<path d="M12 13C12.5523 13 13 12.5523 13 12C13 11.4477 12.5523 11 12 11C11.4477 11 11 11.4477 11 12C11 12.5523 11.4477 13 12 13Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
<path d="M12 6C12.5523 6 13 5.55228 13 5C13 4.44772 12.5523 4 12 4C11.4477 4 11 4.44772 11 5C11 5.55228 11.4477 6 12 6Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
<path d="M12 20C12.5523 20 13 19.5523 13 19C13 18.4477 12.5523 18 12 18C11.4477 18 11 18.4477 11 19C11 19.5523 11.4477 20 12 20Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,package:`<path d="M16.5 9.4L7.5 4.21M21 16V8C20.9996 7.6493 20.9071 7.30483 20.7315 7.00017C20.556 6.69552 20.3037 6.44136 20 6.264L13 2.264C12.696 2.08669 12.3511 1.99377 12 1.99377C11.6489 1.99377 11.304 2.08669 11 2.264L4 6.264C3.69626 6.44136 3.44398 6.69552 3.26846 7.00017C3.09294 7.30483 3.00036 7.6493 3 8V16C3.00036 16.3507 3.09294 16.6952 3.26846 16.9998C3.44398 17.3045 3.69626 17.5586 4 17.736L11 21.736C11.304 21.9133 11.6489 22.0062 12 22.0062C12.3511 22.0062 12.696 21.9133 13 21.736L20 17.736C20.3037 17.5586 20.556 17.3045 20.7315 16.9998C20.9071 16.6952 20.9996 16.3507 21 16Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
<path d="M3.27002 6.96L12 12.01L20.73 6.96M12 22.08V12" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,paragraph:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M11.25 19V5h5.5"/><path d="M14.75 19V5"/><path d="M11.25 12.5a3.75 3.75 0 0 1 0-7.5"/></g>`,pattern:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4.5" width="9" height="15" rx="1.5"/><rect x="15" y="4.5" width="5.5" height="6.25" rx="1.5"/><rect x="15" y="13.25" width="5.5" height="6.25" rx="1.5"/></g>`,"plus-circle":`<path d="M12 8V16M8 12H16M22 12C22 17.5228 17.5228 22 12 22C6.47715 22 2 17.5228 2 12C2 6.47715 6.47715 2 12 2C17.5228 2 22 6.47715 22 12Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,plus:`<path d="M12 5V19M5 12H19" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,preformatted:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4.5" width="17" height="15" rx="2"/><path d="M7 9h6"/><path d="M7 12.25h9.5"/><path d="M7 15.5h4"/></g>`,pullquote:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4.5h16"/><path d="M4 19.5h16"/></g><path d="M11.1 8.35c-2.4.4-3.7 2.05-3.7 4.4v2.95h3.5v-3.55H9.25c.2-1.1.85-1.75 1.85-2.1z" fill="currentColor"/><path d="M16.55 8.35c-2.4.4-3.7 2.05-3.7 4.4v2.95h3.5v-3.55h-1.65c.2-1.1.85-1.75 1.85-2.1z" fill="currentColor"/>`,quote:`<path d="M10.75 6.75c-3.4.6-5.25 2.9-5.25 6.3v4.2h5v-5.1H8.1c.3-1.55 1.2-2.5 2.65-2.95z" fill="currentColor"/><path d="M18.5 6.75c-3.4.6-5.25 2.9-5.25 6.3v4.2h5v-5.1h-2.4c.3-1.55 1.2-2.5 2.65-2.95z" fill="currentColor"/>`,redo:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M16.25 6.25L20 10l-3.75 3.75"/><path d="M20 10H9.5a5.25 5.25 0 0 0-5.25 5.25v2.25"/></g>`,replace:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 8h13"/><path d="M14.75 5.25L17.5 8l-2.75 2.75"/><path d="M19.5 16h-13"/><path d="M9.25 13.25L6.5 16l2.75 2.75"/></g>`,reset:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4.75 4.75V9.5h4.75"/><path d="M4.75 9.5a7.5 7.5 0 1 1-.65 4.75"/></g>`,row:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="7" width="7.75" height="10" rx="1.5"/><rect x="12.75" y="7" width="7.75" height="10" rx="1.5"/></g>`,search:`<path d="M21 21L17.5001 17.5M20 11.5C20 16.1944 16.1944 20 11.5 20C6.80558 20 3 16.1944 3 11.5C3 6.80558 6.80558 3 11.5 3C16.1944 3 20 6.80558 20 11.5Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,separator:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 12h17"/><path d="M9 7.5h6"/><path d="M9 16.5h6"/></g>`,settings:`<path d="M9.3951 19.3711L9.97955 20.6856C10.1533 21.0768 10.4368 21.4093 10.7958 21.6426C11.1547 21.8759 11.5737 22.0001 12.0018 22C12.4299 22.0001 12.8488 21.8759 13.2078 21.6426C13.5667 21.4093 13.8503 21.0768 14.024 20.6856L14.6084 19.3711C14.8165 18.9047 15.1664 18.5159 15.6084 18.26C16.0532 18.0034 16.5678 17.8941 17.0784 17.9478L18.5084 18.1C18.9341 18.145 19.3637 18.0656 19.7451 17.8713C20.1265 17.6771 20.4434 17.3763 20.6573 17.0056C20.8715 16.635 20.9735 16.2103 20.9511 15.7829C20.9286 15.3555 20.7825 14.9438 20.5307 14.5978L19.684 13.4344C19.3825 13.0171 19.2214 12.5148 19.224 12C19.2239 11.4866 19.3865 10.9864 19.6884 10.5711L20.5351 9.40778C20.787 9.06175 20.933 8.65007 20.9555 8.22267C20.978 7.79528 20.8759 7.37054 20.6618 7C20.4479 6.62923 20.131 6.32849 19.7496 6.13423C19.3681 5.93997 18.9386 5.86053 18.5129 5.90556L17.0829 6.05778C16.5722 6.11141 16.0577 6.00212 15.6129 5.74556C15.17 5.48825 14.82 5.09736 14.6129 4.62889L14.024 3.31444C13.8503 2.92317 13.5667 2.59072 13.2078 2.3574C12.8488 2.12408 12.4299 1.99993 12.0018 2C11.5737 1.99993 11.1547 2.12408 10.7958 2.3574C10.4368 2.59072 10.1533 2.92317 9.97955 3.31444L9.3951 4.62889C9.18803 5.09736 8.83798 5.48825 8.3951 5.74556C7.95032 6.00212 7.43577 6.11141 6.9251 6.05778L5.49066 5.90556C5.06499 5.86053 4.6354 5.93997 4.25397 6.13423C3.87255 6.32849 3.55567 6.62923 3.34177 7C3.12759 7.37054 3.02555 7.79528 3.04804 8.22267C3.07052 8.65007 3.21656 9.06175 3.46844 9.40778L4.3151 10.5711C4.61704 10.9864 4.77964 11.4866 4.77955 12C4.77964 12.5134 4.61704 13.0137 4.3151 13.4289L3.46844 14.5922C3.21656 14.9382 3.07052 15.3499 3.04804 15.7773C3.02555 16.2047 3.12759 16.6295 3.34177 17C3.55589 17.3706 3.8728 17.6712 4.25417 17.8654C4.63554 18.0596 5.06502 18.1392 5.49066 18.0944L6.92066 17.9422C7.43133 17.8886 7.94587 17.9979 8.39066 18.2544C8.83519 18.511 9.18687 18.902 9.3951 19.3711Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
<path d="M12 15C13.6568 15 15 13.6569 15 12C15 10.3431 13.6568 9 12 9C10.3431 9 8.99998 10.3431 8.99998 12C8.99998 13.6569 10.3431 15 12 15Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,"share-04":`<path d="M15 3H21L21 9M21 3L13 11M10 5H7.8C6.11984 5 5.27976 5 4.63803 5.32698C4.07354 5.6146 3.6146 6.07354 3.32698 6.63803C3 7.27976 3 8.11984 3 9.8V16.2C3 17.8802 3 18.7202 3.32698 19.362C3.6146 19.9265 4.07354 20.3854 4.63803 20.673C5.27976 21 6.11984 21 7.8 21H14.2C15.8802 21 16.7202 21 17.362 20.673C17.9265 20.3854 18.3854 19.9265 18.673 19.362C19 18.7202 19 17.8802 19 16.2V14" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,share:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="6.5" cy="12" r="2.5"/><circle cx="17" cy="5.75" r="2.5"/><circle cx="17" cy="18.25" r="2.5"/><path d="M8.7 10.7l6.1-3.65"/><path d="M8.7 13.3l6.1 3.65"/></g>`,spacer:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4.75v14.5"/><path d="M8.75 8L12 4.75 15.25 8"/><path d="M8.75 16L12 19.25 15.25 16"/></g>`,stack:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="4.5" y="4" width="15" height="7.25" rx="1.5"/><rect x="4.5" y="12.75" width="15" height="7.25" rx="1.5"/></g>`,sun:`<path d="M12 2V4M12 20V22M4 12H2M6.31412 6.31412L4.8999 4.8999M17.6859 6.31412L19.1001 4.8999M6.31412 17.69L4.8999 19.1042M17.6859 17.69L19.1001 19.1042M22 12H20M17 12C17 14.7614 14.7614 17 12 17C9.23858 17 7 14.7614 7 12C7 9.23858 9.23858 7 12 7C14.7614 7 17 9.23858 17 12Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,symbol:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4l2.75 2.75L12 9.5 9.25 6.75z"/><path d="M6.75 9.25L9.5 12l-2.75 2.75L4 12z"/><path d="M17.25 9.25L20 12l-2.75 2.75L14.5 12z"/><path d="M12 14.5l2.75 2.75L12 20l-2.75-2.75z"/></g>`,sync:`<path d="M21 10C21 10 18.995 7.26822 17.3662 5.63824C15.7373 4.00827 13.4864 3 11 3C6.02944 3 2 7.02944 2 12C2 16.9706 6.02944 21 11 21C15.1031 21 18.5649 18.2543 19.6482 14.5M21 10V4M21 10H15" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,table:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4.5" width="17" height="15" rx="1.5"/><path d="M3.5 10h17"/><path d="M3.5 14.75h17"/><path d="M12 10v9.5"/></g>`,tag:`<path d="M2 12L11.6422 2.35783C11.8405 2.15953 11.9396 2.06038 12.0558 1.98697C12.1588 1.92191 12.2711 1.87276 12.389 1.84115C12.5221 1.80544 12.6631 1.80078 12.945 1.79148L18.2889 1.61571C19.0558 1.59043 19.4392 1.57779 19.7301 1.72C19.9853 1.84519 20.1927 2.04907 20.3223 2.30189C20.4694 2.58969 20.4632 2.97309 20.4507 3.73989L20.3508 9.0844C20.3457 9.36634 20.3432 9.50731 20.3113 9.64061C20.283 9.75858 20.2371 9.87138 20.1751 9.97537C20.105 10.0929 20.0088 10.1946 19.8165 10.3982L10.5 20M2 12L10.5 20M2 12L5 9M10.5 20L13 17" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,trash:`<path d="M9 3H15M3 6H21M19 6L18.2987 16.5193C18.1935 18.0975 18.1409 18.8867 17.8 19.485C17.4999 20.0118 17.0472 20.4353 16.5017 20.6997C15.882 21 15.0911 21 13.5093 21H10.4907C8.90891 21 8.11803 21 7.49834 20.6997C6.95276 20.4353 6.50009 20.0118 6.19998 19.485C5.85911 18.8867 5.8065 18.0975 5.70129 16.5193L5 6M10 10.5V15.5M14 10.5V15.5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,undo:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7.75 6.25L4 10l3.75 3.75"/><path d="M4 10h10.5a5.25 5.25 0 0 1 5.25 5.25v2.25"/></g>`,ungroup:`<g fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><rect x="2.75" y="5.25" width="15.5" height="16" rx="2.25" stroke-dasharray="3.25 2.5"/><rect x="11.75" y="2.75" width="9.5" height="9.5" rx="1.75"/></g>`,upload:`<path d="M21 15V16.2C21 17.8802 21 18.7202 20.673 19.362C20.3854 19.9265 19.9265 20.3854 19.362 20.673C18.7202 21 17.8802 21 16.2 21H7.8C6.11984 21 5.27976 21 4.63803 20.673C4.07354 20.3854 3.6146 19.9265 3.32698 19.362C3 18.7202 3 17.8802 3 16.2V15M17 8L12 3M12 3L7 8M12 3V15" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,user:`<path d="M20 21C20 19.6044 20 18.9067 19.8278 18.3389C19.44 17.0605 18.4395 16.06 17.1611 15.6722C16.5933 15.5 15.8956 15.5 14.5 15.5H9.5C8.10444 15.5 7.40665 15.5 6.83886 15.6722C5.56045 16.06 4.56004 17.0605 4.17224 18.3389C4 18.9067 4 19.6044 4 21M16.5 7.5C16.5 9.98528 14.4853 12 12 12C9.51472 12 7.5 9.98528 7.5 7.5C7.5 5.01472 9.51472 3 12 3C14.4853 3 16.5 5.01472 16.5 7.5Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,users:`<path d="M16 3.46776C17.4817 4.20411 18.5 5.73314 18.5 7.5C18.5 9.26686 17.4817 10.7959 16 11.5322M18 16.7664C19.5115 17.4503 20.8725 18.565 22 20M2 20C3.94649 17.5226 6.58918 16 9.5 16C12.4108 16 15.0535 17.5226 17 20M14 7.5C14 9.98528 11.9853 12 9.5 12C7.01472 12 5 9.98528 5 7.5C5 5.01472 7.01472 3 9.5 3C11.9853 3 14 5.01472 14 7.5Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`,verse:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M19.5 4.5c-6 .75-10 4.5-11.25 10.5L6 19.5"/><path d="M8.5 14.5c3.5-.5 7.5-2.5 9.5-6.5"/></g>`,video:`<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4.5" width="17" height="15" rx="2"/></g><path d="M10.25 9.25l4.75 2.75-4.75 2.75z" fill="currentColor" stroke="none"/>`,"x-close":`<path d="M18 6L6 18M6 6l12 12" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`},co=e=>Object.prototype.hasOwnProperty.call(so,e),lo=(e,t=`publr-icon`)=>e&&co(e)?`#${t}-${e}`:``;function uo(e=document,t=`publr-icon`){let n=e.getElementById(`${t}-sprite`);if(n?.namespaceURI===`http://www.w3.org/2000/svg`)return n;let r=e.createElement(`div`);r.innerHTML=`<svg id="${t}-sprite" style="display:none" aria-hidden="true">${Object.entries(so).map(([e,n])=>`<symbol id="${t}-${e}" viewBox="${oo}">${n}</symbol>`).join(``)}</svg>`;let i=r.firstElementChild;return e.body.appendChild(i),i}var X=(e,t=`h-6 w-6`)=>e in so?`<svg class="${t}" viewBox="${oo}" fill="none" aria-hidden="true">${so[e].replaceAll(`stroke-width="2"`,`stroke-width="1.5"`)}</svg>`:``;function fo(e=document){let t=uo(e,`pbe-i`);t.querySelectorAll(`symbol`).forEach(e=>{e.hasAttribute(`fill`)||e.setAttribute(`fill`,`none`)}),t.querySelectorAll(`[stroke-width="2"]`).forEach(e=>{e.setAttribute(`stroke-width`,`1.5`)})}var po=e=>lo(e,`pbe-i`),mo=`/media/`,ho=`media`,go={"image/png":`png`,"image/jpeg":`jpg`,"image/gif":`gif`,"image/webp":`webp`,"image/avif":`avif`,"image/svg+xml":`svg`,"video/mp4":`mp4`,"video/webm":`webm`,"video/quicktime":`mov`,"audio/mpeg":`mp3`,"audio/wav":`wav`,"audio/ogg":`ogg`,"audio/mp4":`m4a`,"application/pdf":`pdf`};function _o(){return typeof navigator<`u`&&!!navigator.storage?.getDirectory&&!!globalThis.crypto?.subtle}async function vo(){return(await navigator.storage.getDirectory()).getDirectoryHandle(ho,{create:!0})}function yo(e,t){let n=go[e.type];if(n)return n;let r=t?.lastIndexOf(`.`)??-1,i=r>0?t.slice(r+1).toLowerCase():``;return/^[a-z0-9]{1,8}$/.test(i)?i:`bin`}async function bo(e,t){let n=await crypto.subtle.digest(`SHA-256`,await e.arrayBuffer()),r=`${[...new Uint8Array(n)].slice(0,12).map(e=>e.toString(16).padStart(2,`0`)).join(``)}.${yo(e,t)}`,i=await(await(await vo()).getFileHandle(r,{create:!0})).createWritable();return await i.write(e),await i.close(),{url:mo+r,name:r}}async function xo(e){return(await(await vo()).getFileHandle(e)).getFile()}async function So(){let e=await vo(),t=[];for await(let n of e.keys())t.push(n);return t}async function Co(e){let t=await vo();try{return await t.removeEntry(e),!0}catch{return!1}}async function wo(e=`/media-sw.js`){if(!_o()||!(`serviceWorker`in navigator))return!1;try{let t=await navigator.serviceWorker.register(e);return await navigator.serviceWorker.ready,t}catch{return!1}}function To(e,t){return e===!1?{upload:null,browse:null,uploadAvailable:()=>!1,ready:Promise.resolve(!1)}:e===!0||e===void 0?{upload:async e=>({src:(await bo(e,e.name)).url}),browse:null,uploadAvailable:()=>_o()&&!!navigator.serviceWorker?.controller,ready:t?.register?wo().then(e=>!!e):!_o()||!(`serviceWorker`in navigator)?Promise.resolve(!1):navigator.serviceWorker.ready.then(()=>!0,()=>!1)}:{upload:e.upload??null,browse:e.browse??null,uploadAvailable:()=>!!e.upload,ready:Promise.resolve(!0)}}var Eo=e=>e==null||e===``||e===0?``:String(e),Do=e=>new Promise(t=>{let n=new Image;n.onload=()=>t({width:String(n.naturalWidth||``),height:String(n.naturalHeight||``)}),n.onerror=()=>t({width:``,height:``}),n.src=e});async function Oo(e,t={}){let n=e.alt??t.prevAlt??``,r=Eo(e.width),i=Eo(e.height);if(!r&&!i)if(t.file){if(t.file.type.startsWith(`image/`))try{let e=await createImageBitmap(t.file);r=String(e.width),i=String(e.height),e.close()}catch{}}else e.src&&({width:r,height:i}=await Do(e.src));return{src:e.src,alt:n,width:r,height:i}}var Z=`flex h-9 min-w-9 cursor-pointer items-center justify-center gap-0.5 rounded-md px-1.5 text-sm font-semibold text-foreground hover:bg-ui-accent hover:text-accent-foreground focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring disabled:cursor-default disabled:opacity-30 disabled:hover:bg-transparent`,ko=`pbe-ui flex items-stretch gap-0.5 border-r border-border p-1 last:border-r-0`,Ao=`pbe-ui absolute z-40 min-w-56 rounded-lg border border-border bg-popover p-1.5 text-popover-foreground shadow-lg`,jo=`block px-2 py-1.5 text-xs font-semibold text-muted-foreground`,Mo=`flex min-h-9 w-full cursor-pointer items-center gap-2.5 rounded-md px-2.5 py-2 text-left text-sm font-medium text-popover-foreground hover:bg-ui-accent hover:text-accent-foreground focus-visible:bg-ui-accent focus-visible:text-accent-foreground focus-visible:outline-none disabled:cursor-default disabled:opacity-30 disabled:hover:bg-transparent`,No=`shadow-[inset_0_0_0_1.5px_var(--color-pbe-accent)]`,Po=[`bg-ui-accent`,`text-accent-foreground`],Fo=[`text-foreground`,`hover:bg-ui-accent`],Io=e=>`<svg class="h-[15px] w-[15px]" viewBox="0 0 16 16" fill="none" aria-hidden="true">${e}</svg>`,Lo=e=>`<path d="${e}" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>`,Ro=X(`chevron-up`),zo=X(`chevron-down`),Bo=X(`chevron-down`,`h-4 w-4`),Vo=X(`more`),Ho=X(`plus`,`h-5 w-5`),Uo=X(`group-blocks`,`h-5 w-5`),Wo=X(`ungroup`,`h-5 w-5`),Go=X(`link`),Ko=X(`caption`),qo=[{key:`left`,label:`Align text left`,icon:Io(Lo(`M1 3.5h14`)+Lo(`M1 8h8`)+Lo(`M1 12.5h11`))},{key:`center`,label:`Align text center`,icon:Io(Lo(`M1 3.5h14`)+Lo(`M4 8h8`)+Lo(`M2.5 12.5h11`))},{key:`right`,label:`Align text right`,icon:Io(Lo(`M1 3.5h14`)+Lo(`M7 8h8`)+Lo(`M4 12.5h11`))}],Jo=e=>{let t=q(e)?.icon??(e===`raw-html`?`html`:void 0);return t&&X(t,`h-5 w-5`)||(e[0]??`?`).toUpperCase()};function Q(e,t,n){let r=document.createElement(e);return t&&(r.className=t),n!=null&&(r.innerHTML=n),r}function $(e,t,n){let r=Q(`button`,e,t);return r.type=`button`,n&&(r.title=n,r.setAttribute(`aria-label`,n)),r}var Yo=(e,t)=>{Po.forEach(n=>e.classList.toggle(n,t)),Fo.forEach(n=>e.classList.toggle(n,!t))};async function Xo(e){if(navigator.clipboard?.writeText){await navigator.clipboard.writeText(e);return}let t=document.createElement(`textarea`);t.value=e,t.setAttribute(`readonly`,``),t.style.position=`fixed`,t.style.opacity=`0`,document.body.appendChild(t),t.select(),document.execCommand(`copy`),t.remove()}function Zo(e,t={}){let n=t.slash??!0,r=t.inserter??!0,i=t.toolbar??!0,a=t.mediaPlaceholder??!0,o=To(t.media),s=e.canvas,c=t.container??s.parentElement;if(!c)throw Error(`PublrEditor: attachInlineChrome needs a positioned container`);getComputedStyle(c).position===`static`&&(c.style.position=`relative`),s.classList.add(`pbe-canvas`);let l=!1,u=[],d=[],f=e=>(c.appendChild(e),d.push(e),e),p=(e,t)=>{document.addEventListener(e,t),u.push(()=>document.removeEventListener(e,t))},m=e=>s.querySelector(`[data-pb-id="${CSS.escape(e)}"]`),h=e=>{let t=document.createElement(`div`);return t.innerHTML=typeof e==`string`?e:``,t.textContent??``},g=e=>{let t=m(e),n=t&&(t.matches(`[data-pb-rich],[data-pb-text]`)?t:t.querySelector(`[data-pb-rich],[data-pb-text]`));if(!n)return;n.focus({preventScroll:!0});let r=document.createRange();r.selectNodeContents(n),r.collapse(!1);let i=window.getSelection();i?.removeAllRanges(),i?.addRange(r)},_=(e,t,n)=>{let r=c.getBoundingClientRect();e.style.top=`${t-r.top}px`,e.style.left=`${Math.max(0,n-r.left)}px`},v=(e=>{for(let t=e.parentElement;t;t=t.parentElement){let e=getComputedStyle(t).overflowY;if(e===`auto`||e===`scroll`)return t}return null})(c),y=(e,t)=>e.addEventListener(`keydown`,n=>{let r=[...e.querySelectorAll(`button:not([hidden])`)].filter(e=>!e.disabled),i=r.indexOf(document.activeElement);n.key===`ArrowDown`||n.key===`ArrowUp`?(n.preventDefault(),r[n.key===`ArrowDown`?i<r.length-1?i+1:0:i>0?i-1:r.length-1]?.focus()):n.key===`Escape`&&(n.preventDefault(),t())}),b=null;function x(e){S(),b=e,e.el.hidden=!1}function S(){if(!b)return;let e=b;b=null,e.el.hidden=!0,e.onClose?.()}let C=null,w=t=>{let n=C;C=null,S(),n&&e.getBlock(n)&&e.replaceBlock(n,t)},ee=t=>(t?gt(e.getModel().blocks,t)?.parent?.id:null)??null,T=t=>{let n=ee(t);return rt().filter(t=>(n||!t.internal)&&e.canInsertInto(n,t.type))},E=[`paragraph`,`heading`,`image`,`quote`,`list`,`group`],te=e=>{let t=E.map(t=>e.find(e=>e.type===t)).filter(e=>!!e);for(let n of e){if(t.length>=5)break;t.includes(n)||t.push(n)}return t.slice(0,5)},D=n?f(Q(`div`,`${Ao} pbe-quick`)):null,O=[`bg-ui-accent`,`text-accent-foreground`],ne=[`text-foreground`,`hover:bg-ui-accent`],re=[],ie=0,ae=e=>{ie=e,re.forEach((t,n)=>{O.forEach(r=>t.classList.toggle(r,n===e)),ne.forEach(r=>t.classList.toggle(r,n!==e))})},oe=()=>{let n=C;if(C=null,S(),!n)return;let r=e.getBlock(n),i=r&&q(r.type)?.fields.find(e=>e.type===`rich`||e.type===`text`);r&&i&&h(r.fields[i.name]).trim().startsWith(`/`)&&e.setField(n,i.name,``),t.onBrowsePatterns(n)};if(D){D.hidden=!0,D.setAttribute(`role`,`menu`),D.addEventListener(`mousedown`,e=>e.preventDefault()),D.addEventListener(`click`,e=>{let t=e.target instanceof Element?e.target.closest(`button[data-type], button[data-browse-patterns]`):null;t&&(t.dataset.browsePatterns?oe():w(t.dataset.type))});let e=e=>{if(b?.el===D)if(e.key===`ArrowDown`||e.key===`ArrowUp`){e.preventDefault(),e.stopPropagation();let t=re.length;t&&ae(e.key===`ArrowDown`?(ie+1)%t:(ie+t-1)%t)}else e.key===`Enter`?(e.preventDefault(),e.stopPropagation(),re[ie]?.click()):(e.key===`Escape`||e.key===`Tab`)&&(e.preventDefault(),e.stopPropagation(),C=null,S())};document.addEventListener(`keydown`,e,!0),u.push(()=>document.removeEventListener(`keydown`,e,!0))}function k(e){if(!D||!C)return!1;let n=e.trim().toLowerCase(),r=T(C),i=(n?r.filter(e=>e.type.includes(n)||e.label.toLowerCase().includes(n)):te(r)).slice(0,5),a=!!t.onBrowsePatterns&&(!n||`patterns`.includes(n));if(D.textContent=``,re=[],!i.length&&!a)return!1;if(a){D.appendChild(Q(`span`,jo,`Patterns`));let e=$(Mo,``,void 0);e.dataset.browsePatterns=`1`,e.setAttribute(`role`,`menuitem`),e.append(Q(`span`,`flex h-5 w-5 items-center justify-center font-bold`,X(`pattern`,`h-5 w-5`)||`P`),`Pattern`),D.appendChild(e),re.push(e)}i.length&&D.appendChild(Q(`span`,jo,`Blocks`));for(let e of i){let t=$(Mo,``,void 0);t.dataset.type=e.type,t.setAttribute(`role`,`menuitem`),t.append(Q(`span`,`flex h-5 w-5 items-center justify-center font-bold`,Jo(e.type)),e.label),D.appendChild(t),re.push(t)}return ae(0),!0}function se(e){let t=D&&m(e);if(!D||!t)return;if(C=e,!k(``)){C=null;return}let n=t.getBoundingClientRect();_(D,n.bottom+6,n.left),x({el:D})}let A=r?f(Q(`div`,`pbe-ui pbe-inserter absolute z-40 w-[300px] overflow-hidden rounded-lg border border-border bg-popover text-popover-foreground shadow-lg`)):null,ce=Q(`input`,`pbe-search m-3 mb-1 block w-[calc(100%-24px)] rounded-md border border-input bg-background px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:border-ring focus:outline-none focus:ring-2 focus:ring-ring/25`),j=Q(`div`,`pbe-grid grid grid-cols-3 gap-1 px-2 pt-2 pb-3`),M=Q(`div`,`pbe-noresults px-3 pt-1 pb-4 text-center text-[13px] text-muted-foreground`,`No blocks found`),le=t.onBrowseAll?$(`pbe-browseall block w-full cursor-pointer border-t border-border bg-primary p-3 text-center text-sm font-semibold text-primary-foreground hover:bg-primary/90 focus-visible:outline-2 focus-visible:outline-offset-[-3px] focus-visible:outline-ring`,`Browse all`):null,N=f($(`pbe-ui pbe-appender absolute z-30 flex h-8 w-8 cursor-pointer items-center justify-center rounded-lg bg-primary text-primary-foreground shadow-xs hover:bg-primary/90 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring`,Ho,`Add block`));N.hidden=!0;let P=f($(`pbe-ui pbe-spacer-handle absolute z-30 h-3 w-12 cursor-ns-resize rounded-full border border-input bg-background shadow-sm focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring`,``,`Resize spacer`));if(P.hidden=!0,P.addEventListener(`pointerdown`,t=>{let n=P.dataset.target,r=n?m(n):null;if(!n||!r||!e.canStyle(n))return;t.preventDefault(),P.setPointerCapture(t.pointerId);let i=t.clientY,a=r.getBoundingClientRect().height,o=r.style.height,s=Math.max(8,Math.round(a)),c=e=>{s=Math.max(8,Math.round(a+e.clientY-i)),r.style.height=`${s}px`,Fe()},l=()=>{P.removeEventListener(`pointermove`,c),P.removeEventListener(`pointerup`,l),P.removeEventListener(`pointercancel`,l),r.style.height=o,e.setStyle(n,`height`,`${s}px`)};P.addEventListener(`pointermove`,c),P.addEventListener(`pointerup`,l),P.addEventListener(`pointercancel`,l)}),A){A.hidden=!0,ce.type=`text`,ce.placeholder=`Search`,ce.autocomplete=`off`,ce.setAttribute(`aria-label`,`Search for blocks`),M.hidden=!0,A.append(ce,j,M),le&&(A.append(le),le.addEventListener(`click`,()=>{let e=C;C=null,S(),t.onBrowseAll(e)}));let n=()=>[...j.querySelectorAll(`button[data-type]`)],r=()=>n().filter(e=>!e.hidden),i=()=>{let e=ce.value.trim().toLowerCase();for(let t of n())t.hidden=e?!t.dataset.type.includes(e)&&!t.dataset.label.includes(e):t.dataset.quick!==`1`;M.hidden=r().length>0},a=e=>{if(e.dataset.browsePatterns){let e=C;C=null,S(),t.onBrowsePatterns(e)}else w(e.dataset.type)};ce.addEventListener(`input`,i),ce.addEventListener(`keydown`,e=>{if(e.key===`Enter`){e.preventDefault();let t=r()[0];t&&a(t)}else if(e.key===`ArrowDown`)e.preventDefault(),r()[0]?.focus();else if(e.key===`Escape`){e.preventDefault();let t=C;C=null,S(),t&&g(t)}}),j.addEventListener(`click`,e=>{let t=e.target instanceof Element?e.target.closest(`button[data-type]`):null;t&&a(t)}),j.addEventListener(`keydown`,e=>{let t=r(),n=t.indexOf(document.activeElement);if([`ArrowDown`,`ArrowRight`,`ArrowUp`,`ArrowLeft`].includes(e.key))e.preventDefault(),e.key===`ArrowDown`||e.key===`ArrowRight`?t[n<t.length-1?n+1:0]?.focus():n>0?t[n-1].focus():ce.focus();else if(e.key===`Escape`){e.preventDefault();let t=C;C=null,S(),t&&g(t)}}),N.addEventListener(`mousedown`,e=>e.preventDefault()),N.addEventListener(`click`,()=>{let n=N.dataset.target;if(!n||!e.getBlock(n))return;C=n,ce.value=``,j.textContent=``;let r=`flex cursor-pointer flex-col items-center gap-2 rounded-md px-1 pt-3.5 pb-2.5 text-[13px] font-medium text-popover-foreground hover:bg-ui-accent hover:text-accent-foreground focus-visible:bg-ui-accent focus-visible:outline-none`;if(t.onBrowsePatterns){let e=$(r,``);e.dataset.type=`pattern`,e.dataset.label=`pattern`,e.dataset.quick=`1`,e.dataset.browsePatterns=`1`,e.append(Q(`span`,`text-lg leading-none font-bold`,X(`pattern`,`h-5 w-5`)||`P`),`Pattern`),j.appendChild(e)}let a=T(n),o=te(a),s=new Set(o.map(e=>e.type)),l=[...o,...a.filter(e=>!s.has(e.type))];for(let e of l){let t=$(r,``);t.dataset.type=e.type,t.dataset.label=e.label.toLowerCase(),s.has(e.type)&&(t.dataset.quick=`1`),t.append(Q(`span`,`text-lg leading-none font-bold`,Jo(e.type)),e.label),j.appendChild(t)}i();let u=N.getBoundingClientRect(),d=c.getBoundingClientRect();A.hidden=!1,A.style.top=`${u.bottom-d.top+6}px`,A.style.left=`${Math.max(0,u.right-d.left-A.offsetWidth)}px`,x({el:A}),ce.focus()})}let F=i?f(Q(`div`,`pbe-ui pbe-toolbar absolute z-30 flex items-stretch rounded-lg border border-border bg-popover text-popover-foreground shadow-lg`)):null,ue,I,de,fe,L,R,pe,me,z,he,ge,_e,ve,ye,be,xe,B,Se,Ce,V,we,Te,Ee,H=null,De=null,U=null,Oe=null;if(F){F.hidden=!0,F.addEventListener(`mousedown`,e=>e.preventDefault()),V=Q(`div`,`pbe-ui flex items-stretch`),we=Q(`div`,`pbe-ui flex items-stretch`),F.append(V,we),I=Q(`div`,ko),ue=Q(`span`,`flex h-9 min-w-9 items-center justify-center px-1 text-[15px] font-bold text-foreground`),de=$(Z,Ro,`Move up`),fe=$(Z,zo,`Move down`),de.addEventListener(`click`,()=>H&&e.moveBlock(H,-1)),fe.addEventListener(`click`,()=>H&&e.moveBlock(H,1)),I.append(ue,de,fe),Te=Q(`div`,ko),Te.hidden=!0,Ee=$(`${Z} px-2 whitespace-nowrap`,`Edit pattern`),Ee.addEventListener(`click`,()=>{U&&De&&t.onEditPattern(U,De)}),t.onEditPattern&&Te.append(Ee),L=Q(`div`,ko),R=$(Z,X(`bold`,`h-5 w-5`),`Bold`),pe=$(Z,X(`italic`,`h-5 w-5`),`Italic`),me=$(Z,Go,`Link`);let n=t=>{e.format(t),W()};R.addEventListener(`click`,()=>n(`bold`)),pe.addEventListener(`click`,()=>n(`italic`)),me.addEventListener(`click`,()=>{let t=window.getSelection(),n=t?.rangeCount?t.getRangeAt(0).cloneRange():null,r=()=>{if(!n)return;let e=n.commonAncestorContainer;((e instanceof Element?e:e.parentElement)?.closest(`[data-pb-rich]`))?.focus({preventScroll:!0});let t=window.getSelection();t?.removeAllRanges(),t?.addRange(n)},i=e.linkState();ge.open(me,{href:i?.href??``,target:i?.target??``,canRemove:!!i,onApply:(t,n)=>{r(),e.applyLink(t,n)},onRemove:()=>{r(),e.applyLink(``,``)}})}),L.append(R,pe,me),ge=ke(),z=Q(`div`,`pbe-ui flex items-stretch`),z.hidden=!0,he=Q(`div`,`pbe-ui flex items-stretch`),he.hidden=!0,ye=Q(`div`,ko),ve=$(Z,Vo,`Options`),ve.setAttribute(`aria-haspopup`,`menu`),ve.setAttribute(`aria-expanded`,`false`),ye.append(ve),be=f(Q(`div`,`${Ao} pbe-more`)),be.hidden=!0,be.setAttribute(`role`,`menu`),xe=$(Mo,``,`Convert to blocks`),xe.setAttribute(`role`,`menuitem`),xe.append(Q(`span`,`flex h-5 w-5 items-center justify-center`,Wo),`Convert to blocks`),xe.addEventListener(`click`,()=>{S(),H&&e.convertPatternToBlocks(H)}),B=$(Mo,``,`Ungroup (⇧⌘G)`),B.setAttribute(`role`,`menuitem`),B.append(Q(`span`,`flex h-5 w-5 items-center justify-center`,Wo),`Ungroup`),B.addEventListener(`click`,()=>{S(),e.ungroupBlock(H??void 0)}),Se=$(Mo,``,`Duplicate`),Se.setAttribute(`role`,`menuitem`),Se.append(Q(`span`,`flex h-5 w-5 items-center justify-center`,X(`duplicate`,`h-5 w-5`)),`Duplicate`),Se.addEventListener(`click`,()=>{S(),H&&e.duplicateBlock(H)}),Ce=$(Mo,``,`Remove`),Ce.setAttribute(`role`,`menuitem`),Ce.append(Q(`span`,`flex h-5 w-5 items-center justify-center`,X(`trash`,`h-5 w-5`)),`Remove`),Ce.addEventListener(`click`,()=>{S(),H&&e.removeBlock(H)}),be.append(xe,B,Se,Ce),V.append(I,Te,z,L,he,ye);let r=Q(`div`,ko),i=$(`${Z} px-2`,``,`Group (⌘G)`);i.append(Q(`span`,`flex h-5 w-5 items-center justify-center`,Uo),`Group`),i.addEventListener(`click`,()=>void e.groupBlocks()),r.append(i),we.append(r);for(let[e,t]of[[ve,be]])t.addEventListener(`mousedown`,e=>e.preventDefault()),y(t,()=>{S(),e.focus()}),e.addEventListener(`click`,()=>{if(b?.el===t){S();return}let n=e.getBoundingClientRect();_(t,n.bottom+6,n.left),x({el:t,onClose:()=>e.setAttribute(`aria-expanded`,`false`)}),e.setAttribute(`aria-expanded`,`true`),t.querySelector(`button:not([disabled])`)?.focus()});F.addEventListener(`keydown`,e=>{e.key===`Escape`&&!b&&H&&g(H)}),_e=(t,n,r)=>{let i=e.getBlock(n);if(!i)return;let a=i.fields[r],s=a&&typeof a==`object`?a:{src:``,alt:``,width:``,height:``};if(t.textContent=``,o.browse){let e=$(`${Mo} pbe-replace-browse`,``);e.append(Q(`span`,`flex h-5 w-5 items-center justify-center`,X(`gallery`,`h-5 w-5`)),`Media Library`),e.addEventListener(`click`,()=>{S(),We(n,r)}),t.appendChild(e)}if(Ie()){let e=Q(`label`,`${Mo} cursor-pointer`);e.innerHTML=`<span class="flex h-5 w-5 items-center justify-center">${X(`image`,`h-5 w-5`)}</span>Upload<input type="file" class="hidden">`;let i=e.querySelector(`input`);i.addEventListener(`change`,()=>{let e=i.files?.[0];i.value=``,S(),e&&Ue(n,r,e)}),t.appendChild(e)}let c=$(Mo,``);c.append(Q(`span`,`flex h-5 w-5 items-center justify-center`,X(`globe`,`h-5 w-5`)),`Insert from URL`);let l=Q(`form`,`mt-1 mb-1 flex items-center gap-1.5 px-1`);l.hidden=!0;let u=Q(`input`,`h-10 w-full rounded-md border border-input bg-background px-2.5 text-sm text-foreground placeholder:text-muted-foreground focus:border-ring focus:outline-none focus:ring-2 focus:ring-ring/25`);u.type=`text`,u.placeholder=`Paste or type URL`;let d=$(`flex h-10 min-w-10 cursor-pointer items-center justify-center rounded-lg bg-primary px-2 text-sm font-semibold text-primary-foreground shadow-xs hover:bg-primary/90 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring`,`↵`,`Apply`);d.type=`submit`,l.append(u,d),c.addEventListener(`click`,()=>{l.hidden=!l.hidden,l.hidden||(u.value=s.src,u.focus())}),l.addEventListener(`submit`,t=>{t.preventDefault();let i=u.value.trim();S(),e.setField(n,r,{src:i,alt:s.alt,width:``,height:``})}),t.append(c,l);let f=$(Mo,``);if(f.append(Q(`span`,`flex h-5 w-5 items-center justify-center`,X(`reset`,`h-5 w-5`)),`Reset`),f.disabled=!s.src,f.addEventListener(`click`,()=>{S(),e.setField(n,r,{src:``,alt:s.alt,width:``,height:``})}),t.appendChild(f),s.src){let e=Q(`div`,`mt-1.5 border-t border-border px-2.5 pt-2`);e.append(Q(`span`,`block px-2 py-1.5 text-xs font-semibold text-muted-foreground px-0`,`Current media URL`));let n=Q(`a`,`block truncate text-[13px] text-pbe-accent underline`);n.href=s.src,n.textContent=s.src,n.target=`_blank`,n.rel=`noopener`,e.appendChild(n),t.appendChild(e)}};function ke(){let e=f(Q(`div`,`${Ao} pbe-link w-80`));e.hidden=!0,e.setAttribute(`role`,`dialog`);let t=Q(`form`,`flex items-center gap-1.5`),n=Q(`input`,`h-10 w-full rounded-md border border-input bg-background px-2.5 text-sm text-foreground placeholder:text-muted-foreground focus:border-ring focus:outline-none focus:ring-2 focus:ring-ring/25`);n.type=`text`,n.placeholder=`Paste URL or type…`;let r=$(`flex h-10 min-w-10 cursor-pointer items-center justify-center rounded-lg bg-primary px-2 text-sm font-semibold text-primary-foreground shadow-xs hover:bg-primary/90 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring`,`↵`,`Apply`);r.type=`submit`,t.append(n,r);let i=Q(`label`,`mt-2.5 flex cursor-pointer items-center gap-2 px-1 text-sm text-muted-foreground`),a=Q(`input`,`size-4 accent-[var(--color-pbe-accent)]`);a.type=`checkbox`,i.append(a,document.createTextNode(`Open in new tab`));let o=$(`${Mo} mt-1`,``);o.append(Q(`span`,`flex h-5 w-5 items-center justify-center`,Go),`Remove link`),e.append(t,i,o),e.addEventListener(`mousedown`,e=>{e.target!==n&&e.preventDefault()}),e.addEventListener(`keydown`,e=>{if(e.key===`Escape`){e.preventDefault();let t=s?.trigger;S(),t?.focus()}});let s=null;return t.addEventListener(`submit`,e=>{e.preventDefault();let t=s,r=n.value.trim(),i=a.checked?`_blank`:`none`;S(),t?.onApply(r,i)}),o.addEventListener(`click`,()=>{let e=s;S(),e?.onRemove()}),{el:e,open(t,r){s={trigger:t,onApply:r.onApply,onRemove:r.onRemove},n.value=r.href,a.checked=r.target===`_blank`,o.hidden=!r.canRemove;let i=t.getBoundingClientRect();e.hidden=!1,_(e,i.bottom+6,i.left),x({el:e}),n.focus(),n.select()}}}}function Ae(t,n){z.textContent=``,he.textContent=``;let r=e.getBlock(n),i=r?q(r.type):void 0;if(!r){z.hidden=he.hidden=!0;return}let a=new Map,o=(e,t)=>{let n=e.group??`block`,r=a.get(n)??[];r.push(t),a.set(n,r)},s=e=>r.settings&&e in r.settings?r.settings[e]:i?.settings?.find(t=>t.setting===e)?.default,c=(e,t,n=!0)=>{let r=e.getBoundingClientRect();t.hidden=!1,_(t,r.bottom+6,r.left),x({el:t,onClose:()=>{e.setAttribute(`aria-expanded`,`false`),t.remove()}}),e.setAttribute(`aria-expanded`,`true`),n&&t.querySelector(`button:not([disabled]), input`)?.focus()};for(let a of t){if(a.control===`add-child`&&a.type){let t=$(`${Z} px-2 whitespace-nowrap`,a.label,a.label);t.addEventListener(`click`,()=>e.appendChild(n,a.type)),o(a,t);continue}if(a.control===`toggle-setting`&&a.setting){let t=a.icon?X(a.icon):``,r=t?$(Z,t,a.label):$(`${Z} px-2 whitespace-nowrap`,a.label,a.label);Yo(r,s(a.setting)===!0),r.addEventListener(`click`,()=>{let t=e.getBlock(n),r=t?.settings&&a.setting in t.settings?t.settings[a.setting]:i?.settings?.find(e=>e.setting===a.setting)?.default;e.setSetting(n,a.setting,!r)}),o(a,r);continue}if(a.control===`text-align`){let t=e.getStyle(n,`textAlign`)??``,r=$(Z,`${qo.find(e=>e.key===t)?.icon??qo[0].icon}${Bo}`,a.label);r.setAttribute(`aria-haspopup`,`menu`),r.setAttribute(`aria-expanded`,`false`),r.addEventListener(`click`,()=>{let i=f(Q(`div`,`${Ao} pbe-align`));i.setAttribute(`role`,`menu`),i.addEventListener(`mousedown`,e=>e.preventDefault());for(let r of qo){let a=$(`${Mo}${r.key===t?` ${No}`:``}`,``);a.setAttribute(`role`,`menuitem`),a.append(Q(`span`,`flex h-5 w-5 items-center justify-center`,r.icon),r.label),a.addEventListener(`click`,()=>{S(),e.setStyle(n,`textAlign`,r.key===t?``:r.key),g(n)}),i.appendChild(a)}y(i,()=>{S(),r.focus()}),c(r,i)}),o(a,r);continue}if(a.control===`replace`&&a.field){let e=a.icon?X(a.icon):``,t=e?$(Z,`${e}${Bo}`,a.label):$(`${Z} px-2 whitespace-nowrap`,`${a.label}${Bo}`,a.label);t.setAttribute(`aria-haspopup`,`menu`),t.setAttribute(`aria-expanded`,`false`),t.addEventListener(`click`,()=>{let e=f(Q(`div`,`${Ao} pbe-replace w-72`));e.setAttribute(`role`,`menu`),e.addEventListener(`mousedown`,e=>{e.target instanceof HTMLInputElement||e.preventDefault()}),_e(e,n,a.field),e.addEventListener(`keydown`,e=>{e.key===`Escape`&&(e.preventDefault(),S(),t.focus())}),c(t,e,!1)}),o(a,t);continue}if(a.control===`link`&&(a.field||a.setting)){let t=$(Z,Go,a.label),c=a.field?r.fields[a.field]:s(a.setting);Yo(t,(typeof c==`string`?c:``).trim()!==``),t.addEventListener(`click`,()=>{let r=e.getBlock(n);if(!r)return;let o=a.field?r.fields[a.field]:r.settings?.[a.setting]??i?.settings?.find(e=>e.setting===a.setting)?.default,s=a.targetSetting?r.settings?.[a.targetSetting]??i?.settings?.find(e=>e.setting===a.targetSetting)?.default:``;ge.open(t,{href:typeof o==`string`?o:``,target:typeof s==`string`?s:``,canRemove:typeof o==`string`&&o.trim()!==``,onApply:(t,r)=>{a.field?e.setField(n,a.field,t):e.setSetting(n,a.setting,t),a.targetSetting&&e.setSetting(n,a.targetSetting,r===`_blank`?`_blank`:`none`)},onRemove:()=>{a.field?e.setField(n,a.field,``):e.setSetting(n,a.setting,``)}})}),o(a,t);continue}if(a.control===`caption`&&a.field&&a.setting){let t=$(Z,Ko,a.label),c=h(r.fields[a.field]).trim();Yo(t,s(a.setting)===!0||c!==``),t.addEventListener(`click`,()=>{let t=e.getBlock(n);if(!t)return;let r=h(t.fields[a.field]).trim();(t.settings?.[a.setting]??i?.settings?.find(e=>e.setting===a.setting)?.default)===!0||r!==``?(r&&e.setField(n,a.field,``),e.setSetting(n,a.setting,!1)):(e.setSetting(n,a.setting,!0),g(n))}),o(a,t);continue}if(a.control===`copy`&&a.field){let t=$(`${Z} px-2 whitespace-nowrap`,a.label,a.label),i=r.fields[a.field];t.disabled=typeof i!=`string`||!i.trim(),t.addEventListener(`click`,()=>{let t=e.getBlock(n)?.fields[a.field];typeof t==`string`&&t&&Xo(t)}),o(a,t);continue}if(a.control===`text`&&(a.field||a.setting)){let t=$(`${Z} px-2 whitespace-nowrap`,a.label,a.label);t.setAttribute(`aria-haspopup`,`dialog`),t.setAttribute(`aria-expanded`,`false`),t.addEventListener(`click`,()=>{let i=f(Q(`div`,`${Ao} w-72`));i.setAttribute(`role`,`dialog`),i.setAttribute(`aria-label`,a.label);let o=Q(`form`,`flex items-center gap-1.5`),l=Q(`input`,`h-10 w-full rounded-md border border-input bg-background px-2.5 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-2 focus:ring-ring/25`),u=a.field?r.fields[a.field]:s(a.setting);l.type=`text`,l.value=typeof u==`string`?u:``,l.setAttribute(`aria-label`,a.label);let d=$(`flex h-10 min-w-10 cursor-pointer items-center justify-center rounded-lg bg-primary px-2 text-sm font-semibold text-primary-foreground shadow-xs hover:bg-primary/90 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring`,`↵`,`Apply`);d.type=`submit`,o.append(l,d),i.appendChild(o),i.addEventListener(`mousedown`,e=>{e.target!==l&&e.preventDefault()}),i.addEventListener(`keydown`,e=>{e.key===`Escape`&&(e.preventDefault(),S(),t.focus())}),o.addEventListener(`submit`,t=>{t.preventDefault(),S(),a.field?e.setField(n,a.field,l.value):e.setSetting(n,a.setting,l.value)}),c(t,i,!1),l.focus(),l.select()}),o(a,t);continue}if(a.control!==`field-options`&&a.control!==`setting-options`&&a.control!==`transform-options`&&a.control!==`style-options`||!a.options)continue;let t=a.control===`transform-options`?r.type:a.control===`style-options`?e.getStyle(n,a.style):a.field?r.fields[a.field]:s(a.setting),l=a.options.find(e=>e.value===t),u=$(`${Z} px-2 whitespace-nowrap`,`${l?.label??a.label}${Bo}`,a.label);u.setAttribute(`aria-haspopup`,`menu`),u.setAttribute(`aria-expanded`,`false`),u.addEventListener(`click`,()=>{let r=f(Q(`div`,`${Ao} pbe-toolbar-options`));r.setAttribute(`role`,`menu`),r.addEventListener(`mousedown`,e=>e.preventDefault());for(let i of a.options){let o=$(`${Mo}${i.value===t?` ${No}`:``}`,i.label);o.setAttribute(`role`,`menuitem`),o.addEventListener(`click`,()=>{S(),a.control===`transform-options`?e.transformBlock(n,i.value):a.control===`style-options`?e.setStyle(n,a.style,i.value===t?``:i.value):a.field?e.setField(n,a.field,i.value):e.setSetting(n,a.setting,i.value),g(n)}),r.appendChild(o)}y(r,()=>{S(),u.focus()}),c(u,r)}),o(a,u)}for(let e of[`parent`,`block`,`inline`,`other`]){let t=a.get(e);if(!t?.length)continue;let n=Q(`div`,ko);n.dataset.toolbarGroup=e,n.append(...t),(e===`other`?he:z).appendChild(n)}z.hidden=!z.childElementCount,he.hidden=!he.childElementCount}function W(){if(!F||b||F.contains(document.activeElement))return;let n=e.selection.blocks,r=n.length>1,i=r?n[0]:e.selection.active??n[0]??null,a=i?e.getBlock(i):null,o=i?m(i):null;if(!i||!a||!o){F.hidden=!0,H=null;return}if(H=r?null:i,V.hidden=r,we.hidden=!r,!r){let n=e.editingMode(i),r=a.pattern?Ot(a.pattern):void 0;De=r?i:null,U=r?a.pattern:null,Te.hidden=!r||!t.onEditPattern,ue.innerHTML=Jo(r?bt:a.type),ue.title=r?r.label:rt().find(e=>e.type===a.type)?.label??a.type;let s=n==="default"&&e.canMove(i);de.hidden=fe.hidden=!s;let c=gt(e.getModel().blocks,i);de.disabled=!c||c.index<=0,fe.disabled=!c||c.index>=c.list.length-1;let l=[...o.matches(`[data-pb-rich]`)?[o]:[],...o.querySelectorAll(`[data-pb-rich]`)].filter(e=>e.closest(`[data-pb-id]`)===o),u=document.activeElement?.closest?.(`[data-pb-rich]`),d=!!u&&l.includes(u),f=(r?[]:q(a.type)?.toolbar??[]).filter(e=>n==="default"||n===`content-only`&&e.role===`content`),p=window.getSelection(),m=e.selection.active===i&&d&&!!p?.rangeCount&&!p.isCollapsed,h=new Set([`replace`,`link`,`caption`]),g=f.some(e=>h.has(e.control));Ae(m?f.filter(e=>!h.has(e.control)):f,i),L.hidden=g?!m:!d,I.hidden=n!=="default";let _=e.canConvertPattern(i);xe.hidden=!_,xe.disabled=!_;let v=e.ungroupTarget(i);B.hidden=!v,B.disabled=!v,Se.disabled=!e.canDuplicate(i),Ce.disabled=!e.canRemove(i),ye.hidden=n!=="default"||!_&&!v&&Se.disabled&&Ce.disabled;let y=e.formatState(),b=e.blockPolicy(i).allowedFormats,x=e=>b===null||b.includes(e);R.hidden=!x(`bold`),pe.hidden=!x(`italic`),R.disabled=pe.disabled=!d,Yo(R,!!y.bold),Yo(pe,!!y.italic);let S=x(`link`)?e.linkState():null;me.hidden=!x(`link`),me.disabled=!m,Yo(me,!!S)}Oe=i,F.hidden=!1,je()}function je(){if(!F||F.hidden||!Oe)return;let e=m(Oe);if(!e)return;let t=e.getBoundingClientRect(),n=F.offsetHeight,r=t.top-n-10,i=(v?v.getBoundingClientRect().top:0)+8,a=t.bottom-n,o=Math.min(Math.max(r,i),a);o===i&&r<i&&i<a?(F.style.position=`fixed`,F.style.top=`${o}px`,F.style.left=`${Math.max(0,t.left)}px`):(F.style.position=`absolute`,_(F,o,t.left))}let Me=t=>{let n=t?e.getBlock(t):null;if(!n||n.type!==e.defaultBlock)return null;let r=q(n.type)?.fields.find(e=>e.type===`rich`||e.type===`text`);return r?h(n.fields[r.name]).trim():null};function Ne(){if(!n||!D)return;if(b?.el===D){let t=Me(C);if(t==null||!t.startsWith(`/`)||e.selection.active!==C){C=null,S();return}k(t.slice(1))||(C=null,S());return}if(b)return;let t=e.selection.active;t&&Me(t)===`/`&&se(t)}function Pe(){if(!r||b)return;let t=e.selection.active,n=t?e.getBlock(t):null,i=t?m(t):null,a=i&&(i.matches(`[data-pbe-ph].pbe-empty`)?i:i.querySelector(`[data-pbe-ph].pbe-empty`));if(!t||!n||!i||n.type!==e.defaultBlock||!a||!T(t).length){N.hidden=!0;return}let o=s.getBoundingClientRect(),c=i.getBoundingClientRect();N.dataset.target=t,_(N,c.top+(c.height-32)/2,o.right-40),N.hidden=!1}function Fe(){let t=e.selection.blocks,n=e.selection.active??(t.length===1?t[0]:null),r=n?e.getBlock(n):null,i=n?m(n):null;if(!n||!r||r.type!==`spacer`||e.editingMode(n)!=="default"||!e.canStyle(n)||!i){P.hidden=!0,delete P.dataset.target;return}let a=i.getBoundingClientRect();P.dataset.target=n,_(P,a.bottom-6,a.left+a.width/2-24),P.hidden=!1}let Ie=()=>o.uploadAvailable(),Le=e=>(e?q(e)?.settings?.find(e=>e.control===`media`):void 0)?.field??null,Re=e=>[...s.querySelectorAll(`.pbe-media-ph`)].find(t=>t.closest(`[data-pb-block]`)?.getAttribute(`data-pb-id`)===e)??null,ze=`<svg class="h-4 w-4 animate-spin" viewBox="0 0 24 24" fill="none" aria-hidden="true"><circle cx="12" cy="12" r="9" stroke="currentColor" stroke-opacity="0.25" stroke-width="2.5"/><path d="M21 12a9 9 0 0 0-9-9" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"/></svg>`,G=new Map;function Be(e,t){let n=Re(e);if(n){n.setAttribute(`aria-busy`,`true`);let e=n.querySelector(`.pbe-mph-error`);e&&(e.hidden=!0);let r=n.querySelector(`.pbe-mph-busy`);return r&&t&&(r.querySelector(`span`).textContent=t,r.hidden=!1),()=>{n.removeAttribute(`aria-busy`),r&&(r.hidden=!0)}}let r=m(e);if(!t||!r||G.has(e))return()=>{};let i=f(Q(`div`,`pbe-ui pbe-media-busy absolute z-40 flex items-center gap-2 rounded-full border border-border bg-popover px-3 py-1.5 text-sm font-medium text-popover-foreground shadow-lg`));i.setAttribute(`role`,`status`),i.innerHTML=`${ze}<span>${t}</span>`;let a=r.getBoundingClientRect();return _(i,a.top+a.height/2-i.offsetHeight/2,a.left+a.width/2-i.offsetWidth/2),G.set(e,i),()=>{i.remove(),G.delete(e)}}function Ve(e,t){let n=Re(e)?.querySelector(`.pbe-mph-error`);n&&(n.textContent=t,n.hidden=!1)}let He=(t,n)=>{let r=e.getBlock(t)?.fields[n];return typeof r==`object`&&r?r.alt:``};async function Ue(t,n,r){if(!o.upload)return;let i=He(t,n),a=Be(t,`Uploading…`);try{let a=await o.upload(r);e.setField(t,n,await Oo(a,{file:r,prevAlt:i}))}catch(e){console.error(`[publr-editor] media upload failed:`,e),Ve(t,`Upload failed.`)}finally{a()}}async function We(t,n){if(!o.browse)return;let r=e.getBlock(t)?.fields[n],i=typeof r==`object`&&r&&r.src!==``?{...r}:void 0,a=Be(t,null);try{let r=await o.browse(i);r&&e.setField(t,n,await Oo(r,{prevAlt:i?.alt}))}catch(e){console.error(`[publr-editor] media browse failed:`,e),Ve(t,`Couldn't get media from the library.`)}finally{a()}}function Ge(t,n,r){let i=q(r),a=i.label.toLowerCase(),s=document.createElement(`div`);s.className=`pbe-ui pbe-media-ph my-1 rounded-lg border border-border bg-muted p-4 text-foreground`,s.contentEditable=`false`,s.innerHTML=`<div class="mb-1 flex items-center gap-2 font-semibold">${X(i.icon??``,`h-5 w-5`)}<span>${i.label}</span></div><p class="m-0 mb-3 text-sm text-muted-foreground">Drag and drop ${/^[aeiou]/.test(a)?`an`:`a`} ${a} file, upload, or insert from URL.</p><div class="flex flex-wrap items-center gap-2"><label class="pbe-mph-upload inline-flex h-10 cursor-pointer items-center rounded-lg bg-primary px-3.5 text-sm font-semibold text-primary-foreground shadow-xs hover:bg-primary/90"${Ie()?``:` hidden`}>Upload<input type="file" class="hidden"></label>`+(o.browse?`<button type="button" class="pbe-mph-browse h-10 cursor-pointer rounded-lg border border-input bg-background px-3.5 text-sm font-semibold text-foreground shadow-xs hover:bg-ui-accent">Media Library</button>`:``)+`<button type="button" class="pbe-mph-url-btn h-10 cursor-pointer rounded-lg border border-input bg-background px-3.5 text-sm font-semibold text-foreground shadow-xs hover:bg-ui-accent">Insert from URL</button></div><form class="pbe-mph-url-row mt-2 flex items-center gap-1.5" hidden><input type="text" placeholder="Paste or type URL" class="h-10 w-full max-w-96 rounded-md border border-input bg-background px-2.5 text-sm text-foreground placeholder:text-muted-foreground focus:border-ring focus:outline-none focus:ring-2 focus:ring-ring/25"><button type="submit" class="h-10 min-w-10 cursor-pointer rounded-md px-2 text-sm font-semibold hover:bg-ui-accent" aria-label="Apply">↵</button></form><div class="pbe-mph-busy mt-3 flex items-center gap-2 text-sm font-medium text-muted-foreground" role="status" hidden>${ze}<span>Uploading…</span></div><p class="pbe-mph-error mt-2 mb-0 text-sm text-red-600" role="alert" hidden></p>`,s.addEventListener(`mousedown`,n=>{n.stopPropagation(),e.selectBlock(t)}),s.addEventListener(`keydown`,e=>e.stopPropagation());let c=s.querySelector(`input[type=file]`);c.addEventListener(`change`,()=>{let e=c.files?.[0];c.value=``,e&&Ue(t,n,e)}),s.querySelector(`.pbe-mph-browse`)?.addEventListener(`click`,()=>void We(t,n));let l=s.querySelector(`.pbe-mph-url-row`),u=l.querySelector(`input`);return s.querySelector(`.pbe-mph-url-btn`).addEventListener(`click`,()=>{l.hidden=!l.hidden,l.hidden||u.focus()}),l.addEventListener(`submit`,r=>{r.preventDefault();let i=u.value.trim();if(!i)return;let a=e.getBlock(t)?.fields[n],o=typeof a==`object`&&a?a.alt:``;e.setField(t,n,{src:i,alt:o,width:``,height:``})}),s.addEventListener(`dragover`,e=>{e.preventDefault(),s.classList.add(`border-[var(--color-pbe-accent)]`)}),s.addEventListener(`dragleave`,()=>s.classList.remove(`border-[var(--color-pbe-accent)]`)),s.addEventListener(`drop`,e=>{e.preventDefault(),e.stopPropagation(),s.classList.remove(`border-[var(--color-pbe-accent)]`);let r=e.dataTransfer?.files?.[0];r&&Ie()&&Ue(t,n,r)}),s}function Ke(){if(a)for(let t of s.querySelectorAll(`[data-pb-block]`)){let n=t.getAttribute(`data-pb-id`),r=Le(t.getAttribute(`data-pb-block`)),i=[...t.querySelectorAll(`.pbe-media-ph`)].find(e=>e.parentElement?.closest(`[data-pb-block]`)===t),a=n&&r?e.getBlock(n)?.fields[r]:void 0,o=typeof a==`object`&&!!a&&a.src===``;if(!n||!r||!o){i?.remove();continue}if(i){let e=i.querySelector(`.pbe-mph-upload`);e&&(e.hidden=!Ie());continue}[...t.querySelectorAll(`[data-pb-image]`)].find(e=>e.getAttribute(`data-pb-image`)===r&&e.closest(`[data-pb-block]`)===t)?.insertAdjacentElement(`afterend`,Ge(n,r,t.getAttribute(`data-pb-block`)))}}o.ready.then(()=>{l||Ke()}),u.push(()=>{for(let e of s.querySelectorAll(`.pbe-media-ph`))e.remove();for(let e of G.values())e.remove();G.clear()}),p(`mousedown`,e=>{!b||!(e.target instanceof Node)||b.el.contains(e.target)||S()}),p(`selectionchange`,()=>{l||(Pe(),W(),Fe())});let qe=e.subscribe(()=>{l||(Ne(),Pe(),W(),Fe(),Ke())});Ke(),u.push(qe),J(()=>{l||(W(),Fe())});let Je=()=>{!l&&!b&&(je(),Fe())};return(v??window).addEventListener(`scroll`,Je,{passive:!0}),window.addEventListener(`resize`,Je),u.push(()=>(v??window).removeEventListener(`scroll`,Je)),u.push(()=>window.removeEventListener(`resize`,Je)),function(){l=!0,S(),u.forEach(e=>e()),d.forEach(e=>e.remove()),s.classList.remove(`pbe-canvas`)}}var Qo=`<!-- shell.html — the full-harness PAGE chrome, extracted verbatim from the
 demo's index.html and injected by createEditorShell() (src/shell.ts) into a
 host-provided container. The whole shell is ONE PublrJS island: local:chrome.
 Every piece of chrome below is declarative — data-p-show/-text/-class/-bind/
 -style/-model/-for against the chrome store's state, actions by name. The
 imperative opt-outs are the canvas (#canvas, contenteditable), the geometry
 measurements feeding state, and the HOST SEAMS (#host-actions gets the
 host's action buttons, #host-panel-toggles + #host-panels its extra
 sidebars — both rendered imperatively by shell.ts from options).

 The wrapper carries data-p-store="editor": refs that miss the chrome store
 (history.canUndo, undo, redo) resolve up to the editor's own reactive
 stores — core state is bound, never mirrored into chrome. -->
<div class="pbe-shell contents" data-p-store="editor">
  <div
    id="editor-shell"
    data-p-store="local:chrome"
    class="flex h-full flex-col overflow-hidden bg-background text-[13px] leading-[1.4] text-foreground antialiased"
  >
    <!-- Top bar: inserter + history left, document actions
       right. The tools / list-view controls join the left group later. -->
    <header
      id="topbar"
      class="flex h-12 shrink-0 items-center justify-between border-b border-border bg-background px-3"
    >
      <div class="flex items-center gap-0.5">
        <button
          id="inserter-toggle"
          title="Block inserter"
          aria-label="Toggle block inserter"
          data-publr-component="button"
          class="mr-2 flex h-8 w-8 cursor-pointer items-center justify-center rounded-lg bg-primary text-primary-foreground shadow-xs ring-1 ring-transparent ring-inset hover:bg-primary/90 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring aria-expanded:bg-primary/90"
          data-p-bind="aria-expanded:$inserterOpen"
          data-p-on="mousedown.prevent:swallow;click:toggleInserter"
        >
          <svg
            class="h-6 w-6 fill-current"
            viewBox="0 0 24 24"
            aria-hidden="true"
            data-p-show="not:inserterOpen"
          >
            <g
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M12 5.25v13.5" />
              <path d="M5.25 12h13.5" />
            </g>
          </svg>
          <svg
            class="hidden h-6 w-6 fill-current"
            viewBox="0 0 24 24"
            aria-hidden="true"
            data-p-show="$inserterOpen"
          >
            <g
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M6 6l12 12" />
              <path d="M18 6L6 18" />
            </g>
          </svg>
        </button>
        <button
          id="undo"
          title="Undo (⌘Z)"
          aria-label="Undo"
          class="flex h-9 w-9 cursor-pointer items-center justify-center rounded-xs text-neutral-900 hover:bg-neutral-100 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none disabled:cursor-default disabled:opacity-30 disabled:hover:bg-transparent"
          data-p-bind="disabled:not:history.canUndo"
          data-p-on="mousedown.prevent:swallow;click:undo"
        >
          <svg class="h-6 w-6 fill-current" viewBox="0 0 24 24" aria-hidden="true">
            <g
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M7.75 6.25L4 10l3.75 3.75" />
              <path d="M4 10h10.5a5.25 5.25 0 0 1 5.25 5.25v2.25" />
            </g>
          </svg>
        </button>
        <button
          id="redo"
          title="Redo (⇧⌘Z)"
          aria-label="Redo"
          class="flex h-9 w-9 cursor-pointer items-center justify-center rounded-xs text-neutral-900 hover:bg-neutral-100 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none disabled:cursor-default disabled:opacity-30 disabled:hover:bg-transparent"
          data-p-bind="disabled:not:history.canRedo"
          data-p-on="mousedown.prevent:swallow;click:redo"
        >
          <svg class="h-6 w-6 fill-current" viewBox="0 0 24 24" aria-hidden="true">
            <g
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M16.25 6.25L20 10l-3.75 3.75" />
              <path d="M20 10H9.5a5.25 5.25 0 0 0-5.25 5.25v2.25" />
            </g>
          </svg>
        </button>
        <button
          id="tree-toggle"
          title="List view"
          aria-label="Toggle list view"
          class="flex h-9 w-9 cursor-pointer items-center justify-center rounded-xs text-neutral-900 hover:bg-neutral-100 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none aria-expanded:bg-neutral-900 aria-expanded:text-white aria-expanded:hover:bg-neutral-800"
          data-p-bind="aria-expanded:$treeOpen"
          data-p-on="mousedown.prevent:swallow;click:toggleTree"
        >
          <svg class="h-6 w-6 fill-current" viewBox="0 0 24 24" aria-hidden="true">
            <g
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M4 6.5h9.5" />
              <path d="M10.5 12h9.5" />
              <path d="M4 17.5h9.5" />
            </g>
          </svg>
        </button>
      </div>
      <div class="flex items-center gap-0.5">
        <button
          id="preview"
          title="Preview in new tab"
          aria-label="Preview in new tab"
          class="flex h-9 w-9 cursor-pointer items-center justify-center rounded-xs text-neutral-900 hover:bg-neutral-100 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
          data-p-on="mousedown.prevent:swallow;click:preview"
        >
          <svg class="h-6 w-6 fill-current" viewBox="0 0 24 24" aria-hidden="true">
            <g
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M11 5H7a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-4" />
              <path d="M13.75 4.5h5.75v5.75" />
              <path d="M19.5 4.5L11.75 12.25" />
            </g>
          </svg>
        </button>
        <!-- Options menu: the local:dropdown store contract; the items call
           chrome actions (resolved up the island chain). -->
        <div
          id="more-dropdown"
          data-p-store="local:dropdown"
          data-publr-component="dropdown"
          class="flex"
        >
          <div
            id="more-trigger"
            aria-haspopup="menu"
            data-p-bind="aria-expanded:$open"
            data-p-on="click:toggle"
            class="inline-block"
          >
            <button
              type="button"
              title="Options"
              aria-label="Options"
              class="flex h-9 w-9 cursor-pointer items-center justify-center rounded-xs text-neutral-900 hover:bg-neutral-100 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
            >
              <svg class="h-6 w-6 fill-current" viewBox="0 0 24 24" aria-hidden="true">
                <circle cx="12" cy="5.75" r="1.4" />
                <circle cx="12" cy="12" r="1.4" />
                <circle cx="12" cy="18.25" r="1.4" />
              </svg>
            </button>
          </div>
          <div
            id="more-content"
            data-publr-part="content"
            data-p-show="$open"
            role="menu"
            data-p-on="keydown:navKeys;click:itemClick"
            data-p-portal="true"
            data-publr-placement="bottom-end"
            class="absolute z-30 hidden min-w-52 rounded-lg border border-border bg-popover p-1 text-[13px] text-popover-foreground shadow-lg"
          >
            <span
              data-publr-part="label"
              class="block px-2 py-1.5 text-xs font-semibold text-zinc-500"
              >Tools</span
            >
            <button
              type="button"
              id="menu-toggle-output"
              data-publr-part="item"
              role="menuitem"
              class="flex w-full cursor-pointer items-center gap-2 rounded-md px-2 py-[7px] text-left text-sm font-medium text-zinc-900 hover:bg-canvas-accent hover:text-white focus-visible:bg-canvas-accent focus-visible:text-white focus-visible:outline-none"
              data-p-text="$outputShown->'Hide wire output'~'Show wire output'"
              data-p-on="click:toggleOutput"
            ></button>
            <button
              type="button"
              id="menu-copy-editing"
              data-publr-part="item"
              role="menuitem"
              class="flex w-full cursor-pointer items-center gap-2 rounded-md px-2 py-[7px] text-left text-sm font-medium text-zinc-900 hover:bg-canvas-accent hover:text-white focus-visible:bg-canvas-accent focus-visible:text-white focus-visible:outline-none"
              data-p-on="click:copyEditing"
            >
              Copy editing HTML
            </button>
            <button
              type="button"
              id="menu-copy-data"
              data-publr-part="item"
              role="menuitem"
              class="flex w-full cursor-pointer items-center gap-2 rounded-md px-2 py-[7px] text-left text-sm font-medium text-zinc-900 hover:bg-canvas-accent hover:text-white focus-visible:bg-canvas-accent focus-visible:text-white focus-visible:outline-none"
              data-p-on="click:copyData"
            >
              Copy data HTML
            </button>
          </div>
        </div>
        <!-- HOST SEAMS (populated imperatively by shell.ts from options):
           panel toggles first (one icon button per registered host panel),
           then the host's own document actions (Save / Publish / …). -->
        <div id="host-panel-toggles" class="flex items-center gap-0.5 empty:hidden"></div>
        <div
          id="host-actions"
          class="ml-1 flex items-center gap-2 border-l border-border pl-3 empty:hidden empty:border-l-0 empty:pl-0"
        ></div>
      </div>
    </header>

    <!-- Isolation editing banner (thoughts/012): the page document is
       parked and THE editor — full rail, sidebar, list view, toolbar — takes
       the isolated content. Definition mode (from the library): Save =
       versioned publish, copies never move. Instance mode (a placed copy's
       "Edit pattern"): Save applies to that copy only. -->
    <div
      id="template-banner"
      class="flex hidden h-12 shrink-0 items-center justify-between border-b border-accent bg-neutral-50 px-4"
      data-p-show="$templateMode"
    >
      <div class="flex min-w-0 items-center gap-2 text-[13px]">
        <span class="font-medium">Editing pattern:</span>
        <span class="font-semibold" data-p-text="$templateLabel"></span>
        <span class="hidden text-neutral-500 sm:inline" data-p-show="$templateIsInstance"
          >— changes apply only to this copy</span
        >
        <span class="hidden text-neutral-500 sm:inline" data-p-show="not:templateIsInstance"
          >— publishing updates the library design; placed copies never change</span
        >
        <span
          id="template-error"
          class="truncate text-red-600"
          data-p-show="$templateError"
          data-p-text="$templateError"
        ></span>
      </div>
      <div class="flex shrink-0 gap-2">
        <button
          type="button"
          id="template-cancel"
          class="cursor-pointer rounded-xs border border-neutral-300 px-4 py-1.5 text-[13px] font-medium text-neutral-900 hover:bg-neutral-100 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
          data-p-on="mousedown.prevent:swallow;click:cancelTemplate"
        >
          Cancel
        </button>
        <button
          type="button"
          id="template-save"
          class="cursor-pointer rounded-xs bg-accent px-4 py-1.5 text-[13px] font-medium text-white hover:bg-accent-hover focus-visible:shadow-[0_0_0_1.5px_#fff,0_0_0_3px_var(--color-accent)] focus-visible:outline-none"
          data-p-on="mousedown.prevent:swallow;click:saveTemplate"
          data-p-text="$templateIsInstance->'Apply to this copy'~'Publish pattern'"
        ></button>
      </div>
    </div>

    <div id="main" class="flex min-h-0 flex-1 max-sm:flex-col">
      <!-- List view: the document tree. Rows are the block tree
         FLATTENED in chrome state (state.treeRows) — one data-p-for, depth as
         padding — so the recursive structure needs no recursive templates.
         Exclusive with the inserter rail. -->
      <aside
        id="tree"
        class="flex hidden w-[350px] shrink-0 flex-col border-r border-neutral-200 bg-white"
        data-p-show="$treeOpen"
        data-p-on="keydown.escape:closeTree"
      >
        <div class="flex shrink-0 items-center border-b border-neutral-200 pr-2">
          <div id="tree-tabs" role="tablist" aria-label="Document overview" class="flex flex-1">
            <button
              type="button"
              role="tab"
              data-ttab="list"
              class="relative h-12 cursor-pointer px-4 text-[13px] font-medium text-neutral-900 hover:text-accent focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none aria-selected:shadow-[inset_0_-1.5px_0_0_var(--color-accent)]"
              data-p-bind="aria-selected:treeTab|eq|list"
              data-p-on="click:setTreeTab"
            >
              List View
            </button>
            <button
              type="button"
              role="tab"
              data-ttab="outline"
              class="relative h-12 cursor-pointer px-4 text-[13px] font-medium text-neutral-900 hover:text-accent focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none aria-selected:shadow-[inset_0_-1.5px_0_0_var(--color-accent)]"
              data-p-bind="aria-selected:treeTab|eq|outline"
              data-p-on="click:setTreeTab"
            >
              Outline
            </button>
          </div>
          <button
            type="button"
            id="tree-close"
            aria-label="Close list view"
            class="flex h-9 w-9 cursor-pointer items-center justify-center rounded-xs text-neutral-900 hover:bg-neutral-100 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
            data-p-on="click:closeTree"
          >
            <svg class="h-6 w-6 fill-current" viewBox="0 0 24 24" aria-hidden="true">
              <g
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path d="M6 6l12 12" />
                <path d="M18 6L6 18" />
              </g>
            </svg>
          </button>
        </div>
        <div id="tpanel-list" class="flex-1 overflow-y-auto p-2" data-p-show="treeTab|eq|list">
          <div id="tree-rows">
            <template data-p-for="row of $treeRows" data-p-key="row.id">
              <div
                class="flex items-center rounded-sm"
                data-p-style="padding-left->row.pad"
                data-p-class="row.selected->bg-ui-accent+text-accent-foreground~hover:bg-ui-accent"
              >
                <button
                  type="button"
                  aria-label="Toggle children"
                  class="flex h-6 w-6 shrink-0 cursor-pointer items-center justify-center"
                  data-p-class="not:row.hasChildren->invisible"
                  data-p-bind="data-id:row.id"
                  data-p-on="mousedown.prevent:swallow;click.stop:treeToggle"
                >
                  <svg
                    class="h-3 w-3 fill-current transition-transform"
                    viewBox="0 0 12 12"
                    aria-hidden="true"
                    data-p-class="row.expanded->rotate-90"
                  >
                    <path
                      d="M4.25 2.5L8 6 4.25 9.5"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="1.4"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    />
                  </svg>
                </button>
                <!-- mousedown is swallowed (chrome convention): an unprevented
                   mousedown outside the canvas CLEARS the explicit block
                   selection — Cmd+click accumulation needs it to survive. -->
                <button
                  type="button"
                  class="flex min-w-0 flex-1 cursor-pointer items-center gap-2 py-2 pr-2 text-left"
                  data-p-bind="data-id:row.id"
                  data-p-on="mousedown.prevent:swallow;click:treeSelect"
                >
                  <!-- Icon = sprite ref (bindable attribute — PublrJS has no
                     html injection); blocks without one get a letter badge. -->
                  <span class="flex w-6 shrink-0 items-center justify-center">
                    <svg
                      class="h-6 w-6 fill-current"
                      viewBox="0 0 24 24"
                      aria-hidden="true"
                      data-p-show="row.icon"
                    >
                      <use data-p-bind="href:row.icon" />
                    </svg>
                    <span
                      class="text-[13px] font-bold"
                      data-p-show="not:row.icon"
                      data-p-text="row.letter"
                    ></span>
                  </span>
                  <span class="shrink-0 font-medium" data-p-text="row.label"></span>
                  <span class="truncate opacity-60" data-p-text="row.anchor"></span>
                </button>
              </div>
            </template>
          </div>
        </div>
        <div
          id="tpanel-outline"
          class="hidden flex-1 overflow-y-auto"
          data-p-show="treeTab|eq|outline"
        >
          <dl
            class="grid grid-cols-[auto_1fr] gap-x-10 gap-y-2.5 border-b border-neutral-200 px-4 py-4"
          >
            <dt class="text-neutral-700">Characters:</dt>
            <dd id="stat-chars" class="m-0" data-p-text="$docChars"></dd>
            <dt class="text-neutral-700">Words:</dt>
            <dd id="stat-words" class="m-0" data-p-text="$docWords"></dd>
            <dt class="text-neutral-700">Time to read:</dt>
            <dd id="stat-readtime" class="m-0" data-p-text="$docReadTime"></dd>
          </dl>
          <div id="outline-rows" class="px-4 py-3">
            <template data-p-for="h of $outlineRows" data-p-key="h.id">
              <button
                type="button"
                class="flex w-full cursor-pointer items-center py-1.5 text-left hover:text-accent"
                data-p-bind="data-id:h.id"
                data-p-on="mousedown.prevent:swallow;click:treeSelect"
              >
                <span
                  class="mt-4 h-px shrink-0 self-start bg-neutral-300"
                  data-p-style="width->h.guide"
                ></span>
                <!-- \`~\` = else-branch: conflicting utilities SWAP, never stack
                   (CSS order, not class order, decides ties) -->
                <span
                  class="mr-2 ml-1 shrink-0 self-start rounded-sm bg-neutral-200 px-1.5 py-0.5 text-[13px] font-semibold"
                  data-p-class="h.flagged->bg-amber-300~bg-neutral-200"
                  data-p-text="h.level"
                ></span>
                <span class="min-w-0 py-0.5">
                  <span
                    class="block truncate"
                    data-p-class="h.empty->italic+text-neutral-600"
                    data-p-text="h.text"
                  ></span>
                  <span
                    class="block hidden truncate italic text-neutral-600"
                    data-p-show="h.badLevel"
                    >(Incorrect heading level)</span
                  >
                </span>
              </button>
            </template>
            <p class="text-neutral-500" data-p-show="$outlineEmpty">
              Add headings to create a table of contents for the document.
            </p>
          </div>
        </div>
      </aside>

      <!-- Full block inserter: left rail, the block library. The
         Blocks tab renders from state.shelves (grouped + filtered in the
         chrome store); Patterns and Media are placeholders. -->
      <aside
        id="inserter"
        class="flex hidden w-[350px] shrink-0 flex-col border-r border-neutral-200 bg-white"
        data-p-show="$inserterOpen"
        data-p-on="keydown.escape:closeInserter"
      >
        <div class="flex shrink-0 items-center border-b border-neutral-200 pr-2">
          <div id="inserter-tabs" role="tablist" aria-label="Block library" class="flex flex-1">
            <button
              type="button"
              role="tab"
              data-itab="blocks"
              class="relative h-12 cursor-pointer px-4 text-[13px] font-medium text-neutral-900 hover:text-accent focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none aria-selected:shadow-[inset_0_-1.5px_0_0_var(--color-accent)]"
              data-p-bind="aria-selected:inserterTab|eq|blocks"
              data-p-on="click:setInserterTab"
            >
              Blocks
            </button>
            <button
              type="button"
              role="tab"
              data-itab="patterns"
              class="relative h-12 cursor-pointer px-4 text-[13px] font-medium text-neutral-900 hover:text-accent focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none aria-selected:shadow-[inset_0_-1.5px_0_0_var(--color-accent)]"
              data-p-bind="aria-selected:inserterTab|eq|patterns"
              data-p-on="click:setInserterTab"
            >
              Patterns
            </button>
            <button
              type="button"
              role="tab"
              data-itab="media"
              class="relative h-12 cursor-pointer px-4 text-[13px] font-medium text-neutral-900 hover:text-accent focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none aria-selected:shadow-[inset_0_-1.5px_0_0_var(--color-accent)]"
              data-p-bind="aria-selected:inserterTab|eq|media"
              data-p-on="click:setInserterTab"
            >
              Media
            </button>
          </div>
          <button
            type="button"
            id="inserter-close"
            aria-label="Close block inserter"
            class="flex h-9 w-9 cursor-pointer items-center justify-center rounded-xs text-neutral-900 hover:bg-neutral-100 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
            data-p-on="click:closeInserter"
          >
            <svg class="h-6 w-6 fill-current" viewBox="0 0 24 24" aria-hidden="true">
              <g
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path d="M6 6l12 12" />
                <path d="M18 6L6 18" />
              </g>
            </svg>
          </button>
        </div>
        <div
          id="ipanel-blocks"
          class="flex-1 overflow-y-auto p-4"
          data-p-show="inserterTab|eq|blocks"
        >
          <div class="relative mb-2">
            <svg
              class="pointer-events-none absolute top-1/2 left-3 -translate-y-1/2 text-neutral-900"
              viewBox="0 0 24 24"
              fill="none"
              width="18"
              height="18"
              aria-hidden="true"
            >
              <circle cx="11" cy="11" r="7" stroke="currentColor" stroke-width="1.5" />
              <path
                d="M20 20l-3.5-3.5"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
              />
            </svg>
            <input
              id="library-search"
              type="text"
              placeholder="Search"
              autocomplete="off"
              aria-label="Search for blocks"
              class="w-full rounded-xs border border-neutral-400 py-2.5 pr-3 pl-10 text-[13px] text-neutral-900 placeholder:text-neutral-500 focus:border-accent focus:shadow-[0_0_0_0.5px_var(--color-accent)] focus:outline-none"
              data-p-model="$query|trim"
              data-p-on="keydown.enter.prevent:libraryPickFirst"
            />
          </div>
          <div id="library-sections">
            <template data-p-for="shelf of $shelves" data-p-key="shelf.name">
              <section class="library-category">
                <h3
                  class="library-category-title mt-6 py-2 text-[11px] font-medium tracking-wider text-neutral-500 uppercase"
                  data-p-text="shelf.name"
                ></h3>
                <div class="grid grid-cols-3">
                  <template data-p-for="b of shelf.blocks" data-p-key="b.type">
                    <button
                      type="button"
                      class="library-item flex cursor-pointer flex-col items-center gap-3 rounded-xs px-1 pt-5 pb-4 text-[13px] text-neutral-900 hover:bg-neutral-100 focus-visible:bg-neutral-100 focus-visible:outline-none"
                      data-p-bind="data-block-type:b.type"
                      data-p-on="click:pickBlock"
                    >
                      <span class="icon flex h-6 items-center justify-center">
                        <svg
                          class="h-6 w-6 fill-current"
                          viewBox="0 0 24 24"
                          aria-hidden="true"
                          data-p-show="b.icon"
                        >
                          <use data-p-bind="href:b.icon" />
                        </svg>
                        <span
                          class="text-lg font-semibold"
                          data-p-show="not:b.icon"
                          data-p-text="b.letter"
                        ></span>
                      </span>
                      <span data-p-text="b.label"></span>
                    </button>
                  </template>
                </div>
              </section>
            </template>
          </div>
          <p id="library-empty" class="hidden py-4 text-neutral-500" data-p-show="$noResults">
            No results found.
          </p>
        </div>
        <div
          id="ipanel-patterns"
          class="hidden flex-1 flex-col overflow-y-auto p-4"
          data-p-show="inserterTab|eq|patterns"
        >
          <div class="relative mb-4">
            <svg
              class="pointer-events-none absolute top-1/2 left-3 -translate-y-1/2 text-neutral-900"
              viewBox="0 0 24 24"
              fill="none"
              width="18"
              height="18"
              aria-hidden="true"
            >
              <circle cx="11" cy="11" r="7" stroke="currentColor" stroke-width="1.5" />
              <path
                d="M20 20l-3.5-3.5"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
              />
            </svg>
            <input
              id="pattern-search"
              type="text"
              placeholder="Search"
              autocomplete="off"
              aria-label="Search for patterns"
              class="w-full rounded-xs border border-neutral-400 py-2.5 pr-3 pl-10 text-[13px] text-neutral-900 placeholder:text-neutral-500 focus:border-accent focus:shadow-[0_0_0_0.5px_var(--color-accent)] focus:outline-none"
              data-p-model="$patternQuery|trim"
            />
          </div>
          <!-- Group rows: picking one opens the preview flyout right of the
             rail; picking it again folds the flyout. A live search overrides
             the group pick (the flyout shows matches instead). -->
          <div id="pattern-groups" class="flex flex-col gap-1">
            <template data-p-for="g of $patternGroups" data-p-key="g.name">
              <button
                type="button"
                class="pattern-group-row flex w-full cursor-pointer items-center justify-between rounded-xs border px-4 py-3 text-left text-[13px] font-medium focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
                data-p-class="g.selected->border-input+bg-ui-accent+text-accent-foreground~border-input+text-foreground+hover:bg-ui-accent"
                data-p-bind="data-group:g.name"
                data-p-on="click:pickPatternGroup"
              >
                <span data-p-text="g.name"></span>
                <svg
                  class="h-4 w-4 fill-current"
                  viewBox="0 0 24 24"
                  aria-hidden="true"
                  data-p-class="not:g.selected->invisible"
                >
                  <g
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                  >
                    <path d="M9.5 6l6 6-6 6" />
                  </g>
                </svg>
              </button>
            </template>
          </div>
          <button
            type="button"
            id="pattern-explore"
            class="mt-6 w-full shrink-0 cursor-pointer rounded-xs border border-neutral-900 py-2.5 text-[13px] font-medium text-neutral-900 hover:bg-neutral-100 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
            data-p-on="click:openPatternExplorer"
          >
            Explore all patterns
          </button>
        </div>
        <div
          id="ipanel-media"
          class="hidden flex-1 overflow-y-auto p-4"
          data-p-show="inserterTab|eq|media"
        >
          <p class="text-neutral-500">Media arrives with a later step.</p>
        </div>
      </aside>

      <!-- Patterns preview flyout: opens right of the rail when a group is
         selected (or a search is typed) on the Patterns tab. Cards are LIVE
         previews — the fragment rendered through the real cast pipeline and
         scaled down (filled imperatively; PublrJS has no HTML-injection
         binding by design). -->
      <aside
        id="pattern-flyout"
        class="flex hidden w-[350px] shrink-0 flex-col border-r border-border bg-card"
        data-p-show="$patternFlyoutOpen"
      >
        <h2
          class="shrink-0 px-4 pt-4 text-[15px] font-semibold"
          data-p-text="$patternFlyoutTitle"
        ></h2>
        <p class="shrink-0 px-4 pt-1 pb-3 text-[13px] text-neutral-500">
          Click a pattern to add it to the canvas.
        </p>
        <div class="flex-1 overflow-y-auto px-4 pb-4">
          <template data-p-for="p of $patternItems" data-p-key="p.name">
            <div class="pattern-card group mb-4">
              <button
                type="button"
                class="group block w-full cursor-pointer text-left focus-visible:outline-none"
                data-p-bind="data-pattern:p.name;aria-label:p.label"
                data-p-on="click:pickPattern"
              >
                <span
                  class="block w-full overflow-hidden rounded-xs border border-neutral-200 bg-white group-hover:border-accent group-focus-visible:border-accent"
                  data-p-bind="data-pattern-preview:p.name"
                ></span>
              </button>
              <span class="mt-1.5 flex items-center justify-between">
                <span class="text-xs font-medium text-neutral-700" data-p-text="p.label"></span>
                <!-- the LIBRARY's edit affordance — publishing never moves placed copies.
                   tabindex=-1: keyboard focus walks CARD to CARD, one stop per
                   pattern — Edit stays a pointer affordance. -->
                <button
                  type="button"
                  tabindex="-1"
                  class="pattern-edit cursor-pointer rounded-xs px-1.5 py-0.5 text-[11px] font-medium text-neutral-500 hover:bg-neutral-100 hover:text-accent focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
                  aria-label="Edit pattern in the library"
                  data-p-bind="data-pattern:p.name"
                  data-p-on="click:editDefinition"
                >
                  Edit
                </button>
              </span>
            </div>
          </template>
          <p class="text-[13px] text-neutral-500" data-p-show="$patternNoResults">
            No patterns found.
          </p>
        </div>
      </aside>

      <div id="editor-column" class="flex min-w-0 flex-1 flex-col max-sm:basis-1/2">
        <div id="editor-content" class="flex-1 overflow-y-auto">
          <div class="wrap relative mx-auto w-full px-5 pt-12 pb-20 text-[15px] leading-[1.6]">
            <!-- The in-canvas chrome (floating toolbar, "/" quick picker, inline +
               inserter) is NOT in this markup: demo.ts attaches the SHIPPED layer
               (attachInlineChrome) against this .wrap — the same batteries every
               embedder gets. Only page chrome is hand-built here. -->
            <main id="canvas" class="min-h-60 cursor-text pb-24"></main>

            <!-- Dev panes: hidden behind the ⋮ menu's "Show wire output". -->
            <section id="output-section" class="hidden" data-p-show="$outputShown">
              <h2 class="mt-7 mb-2 text-xs font-semibold tracking-wide text-zinc-500 uppercase">
                Downcast editing pipeline (full wire contract, live)
              </h2>
              <pre
                id="output-editing"
                class="m-0 rounded-lg bg-zinc-900 p-4 font-mono text-xs leading-normal break-words whitespace-pre-wrap text-zinc-300"
                data-p-text="$wireEditing"
              ></pre>
              <h2 class="mt-7 mb-2 text-xs font-semibold tracking-wide text-zinc-500 uppercase">
                Downcast data pipeline (published shape — data-pb-* stripped)
              </h2>
              <pre
                id="output-data"
                class="m-0 rounded-lg bg-zinc-900 p-4 font-mono text-xs leading-normal break-words whitespace-pre-wrap text-zinc-300"
                data-p-text="$wireData"
              ></pre>
            </section>
          </div>
        </div>
        <footer
          id="footer"
          class="flex h-[25px] shrink-0 items-center border-t border-neutral-200 bg-white px-[18px] text-xs"
        >
          <span id="breadcrumb" data-p-text="$breadcrumb"></span>
        </footer>
      </div>

      <aside
        id="sidebar"
        data-pbe-keep-selection
        class="flex w-[281px] shrink-0 flex-col overflow-y-auto border-l border-neutral-200 bg-white max-sm:min-h-0 max-sm:w-full max-sm:flex-1 max-sm:basis-1/2 max-sm:border-t max-sm:border-l-0"
      >
        <div
          id="sidebar-tabs"
          role="tablist"
          aria-label="Editor settings"
          class="flex shrink-0 border-b border-neutral-200"
        >
          <button
            type="button"
            role="tab"
            data-tab="document"
            class="relative h-12 cursor-pointer px-4 text-[13px] font-medium text-neutral-900 hover:text-accent focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none aria-selected:shadow-[inset_0_-1.5px_0_0_var(--color-accent)]"
            data-p-bind="aria-selected:sidebarTab|eq|document"
            data-p-on="mousedown.prevent:swallow;click:setSidebarTab"
          >
            Document
          </button>
          <button
            type="button"
            role="tab"
            data-tab="block"
            class="relative h-12 cursor-pointer px-4 text-[13px] font-medium text-neutral-900 hover:text-accent focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none aria-selected:shadow-[inset_0_-1.5px_0_0_var(--color-accent)]"
            data-p-bind="aria-selected:sidebarTab|eq|block"
            data-p-on="mousedown.prevent:swallow;click:setSidebarTab"
          >
            Block
          </button>
          <button
            type="button"
            role="tab"
            data-tab="design"
            class="relative h-12 cursor-pointer px-4 text-[13px] font-medium text-neutral-900 hover:text-accent focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none aria-selected:shadow-[inset_0_-1.5px_0_0_var(--color-accent)]"
            data-p-bind="aria-selected:sidebarTab|eq|design"
            data-p-on="mousedown.prevent:swallow;click:setSidebarTab"
          >
            Design
          </button>
        </div>
        <div id="panel-document" class="p-4" role="tabpanel" data-p-show="sidebarTab|eq|document">
          <!-- document overview arrives with a later step -->
        </div>
        <div id="panel-block" class="hidden p-4" role="tabpanel" data-p-show="sidebarTab|eq|block">
          <p
            id="block-empty"
            class="m-0 text-neutral-500"
            data-p-show="not:blockSelected"
            data-p-text="$emptyNote"
          ></p>
          <div id="block-card" class="hidden" data-p-show="$blockSelected">
            <div class="flex items-start gap-3">
              <span id="block-card-icon" class="flex h-6 w-6 shrink-0 items-center justify-center">
                <svg
                  class="h-6 w-6 fill-current"
                  viewBox="0 0 24 24"
                  aria-hidden="true"
                  data-p-show="$blockIcon"
                >
                  <use data-p-bind="href:$blockIcon" />
                </svg>
                <span
                  class="text-[15px] font-bold"
                  data-p-show="not:blockIcon"
                  data-p-text="$blockLetter"
                ></span>
              </span>
              <div>
                <div class="mb-1 flex items-center gap-2">
                  <span
                    id="block-card-title"
                    class="font-semibold"
                    data-p-text="$blockLabel"
                  ></span>
                  <span
                    id="block-card-pattern-chip"
                    class="hidden rounded-xs bg-neutral-100 px-1.5 py-0.5 text-[11px] font-medium text-neutral-600"
                    data-p-show="$blockIsPattern"
                    >Pattern</span
                  >
                </div>
                <p
                  id="block-card-description"
                  class="m-0 text-neutral-500"
                  data-p-text="$blockDescription"
                ></p>
              </div>
            </div>
            <div
              class="mt-5 flex border-b border-neutral-200"
              role="tablist"
              aria-label="Block inspector"
              data-p-show="not:blockIsPattern"
            >
              <button
                type="button"
                role="tab"
                data-itab="settings"
                class="relative h-10 flex-1 cursor-pointer text-[13px] font-medium aria-selected:shadow-[inset_0_-1.5px_0_0_var(--color-accent)]"
                data-p-bind="aria-selected:blockInspectorTab|eq|settings"
                data-p-on="mousedown.prevent:swallow;click:setBlockInspectorTab"
              >
                Settings
              </button>
              <button
                type="button"
                role="tab"
                data-itab="styles"
                class="relative hidden h-10 flex-1 cursor-pointer text-[13px] font-medium aria-selected:shadow-[inset_0_-1.5px_0_0_var(--color-accent)]"
                data-p-show="$blockHasStyles"
                data-p-bind="aria-selected:blockInspectorTab|eq|styles;disabled:not:blockHasStyles"
                data-p-on="mousedown.prevent:swallow;click:setBlockInspectorTab"
              >
                Styles
              </button>
            </div>
            <!-- Pattern instance (thoughts/012): a fully DECOUPLED copy.
               One action — Edit pattern, over THIS copy — plus the copy's
               Content outline. Template-only options land
               here later. -->
            <div
              id="pattern-actions"
              class="mt-5 flex hidden flex-col gap-2"
              data-p-show="$blockIsPattern"
            >
              <button
                type="button"
                id="sidebar-edit-pattern"
                class="w-full cursor-pointer rounded-xs border border-accent py-2.5 text-[13px] font-medium text-accent hover:bg-neutral-100 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
                data-p-on="click:sidebarEditPattern"
              >
                Edit pattern
              </button>
              <div id="pattern-content" class="mt-4">
                <h3
                  class="m-0 border-b border-neutral-200 pb-2 text-[11px] font-semibold tracking-wider text-neutral-500 uppercase"
                >
                  Content
                </h3>
                <template data-p-for="row of $blockPatternContent" data-p-key="row.id">
                  <button
                    type="button"
                    class="flex w-full cursor-pointer items-center gap-2 rounded-xs px-1 py-2 text-left text-[13px] focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
                    data-p-class="row.selected->bg-ui-accent+text-accent-foreground~hover:bg-ui-accent"
                    data-p-bind="data-id:row.id"
                    data-p-on="mousedown.prevent:swallow;click:selectPatternChild"
                  >
                    <span class="flex h-5 w-5 shrink-0 items-center justify-center">
                      <svg
                        class="h-5 w-5 fill-current"
                        viewBox="0 0 24 24"
                        aria-hidden="true"
                        data-p-show="row.icon"
                      >
                        <use data-p-bind="href:row.icon" />
                      </svg>
                      <span
                        class="text-[13px] font-bold"
                        data-p-show="not:row.icon"
                        data-p-text="row.letter"
                      ></span>
                    </span>
                    <span class="shrink-0 font-medium" data-p-text="row.label"></span>
                    <span
                      class="truncate"
                      data-p-class="row.selected->text-muted-foreground~text-muted-foreground"
                      data-p-text="row.anchor"
                    ></span>
                  </button>
                </template>
              </div>
            </div>
            <!-- Declared block settings (registry SettingSpecs joined with the
               selected block in chrome state). ONE branch per control kind,
               switched on the row's precomputed isChoice/isToggle/… flags.
               Every control writes through a dataset-routed action: the
               dataset carries primitive + target. -->
            <div id="block-settings" class="hidden" data-p-show="blockInspectorTab|eq|settings">
              <template data-p-for="row of $blockSettings" data-p-key="row.key">
                <div class="mt-5" role="group" data-p-bind="aria-label:row.label">
                  <div
                    class="mb-3 flex items-center justify-between border-b border-neutral-200 pb-2"
                    data-p-show="row.showSection"
                  >
                    <button
                      type="button"
                      class="flex cursor-pointer items-center gap-1 text-[11px] font-semibold tracking-wider text-neutral-500 uppercase"
                      data-p-bind="data-section:row.sectionKey;aria-expanded:row.sectionExpanded"
                      data-p-on="mousedown.prevent:swallow;click:toggleSettingSection"
                    >
                      <span data-p-text="row.section"></span><span aria-hidden="true">⌄</span>
                    </button>
                    <button
                      type="button"
                      class="cursor-pointer text-[11px] font-medium text-neutral-500 hover:text-neutral-900"
                      data-p-bind="data-id:row.id;data-role:row.sectionRole"
                      data-p-on="mousedown.prevent:swallow;click:resetSettingSection"
                    >
                      Reset
                    </button>
                  </div>
                  <div class="hidden" data-p-show="row.sectionExpanded">
                    <!-- toggle-group: option buttons (field / transform / island-bound) -->
                    <div class="flex flex-wrap gap-1" data-p-show="row.isChoice">
                      <template data-p-for="opt of row.options" data-p-key="opt.value">
                        <!-- Icon when the option declares one, label text otherwise;
                         either way the label stays the accessible name. -->
                        <button
                          type="button"
                          class="flex h-10 min-w-10 cursor-pointer items-center justify-center rounded-xs px-1.5 text-[13px] font-semibold text-neutral-500 hover:text-neutral-900 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none aria-pressed:bg-neutral-100 aria-pressed:text-neutral-900 aria-pressed:shadow-[inset_0_0_0_1px_var(--color-neutral-400)]"
                          data-p-bind="data-id:row.id;data-mode:row.mode;data-field:row.field;data-setting:row.setting;data-value:opt.value;aria-pressed:opt.pressed;aria-label:opt.label;title:opt.label"
                          data-p-on="mousedown.prevent:swallow;click:applySetting"
                        >
                          <svg
                            class="h-6 w-6 fill-current"
                            viewBox="0 0 24 24"
                            aria-hidden="true"
                            data-p-show="opt.icon"
                          >
                            <use data-p-bind="href:opt.icon" />
                          </svg>
                          <span data-p-show="not:opt.icon" data-p-text="opt.label"></span>
                        </button>
                      </template>
                    </div>
                    <!-- toggle: visible label + switch -->
                    <div class="flex items-center justify-between" data-p-show="row.isToggle">
                      <span
                        class="text-[13px] font-medium text-neutral-700"
                        data-p-text="row.label"
                      ></span>
                      <button
                        type="button"
                        role="switch"
                        class="relative h-5 w-9 cursor-pointer rounded-full bg-neutral-300 transition-colors after:absolute after:top-0.5 after:left-0.5 after:h-4 after:w-4 after:rounded-full after:bg-white after:transition-transform aria-checked:bg-[var(--color-accent)] aria-checked:after:translate-x-4 focus-visible:shadow-[0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
                        data-p-bind="data-id:row.id;data-setting:row.setting;data-pressed:row.value;aria-checked:row.pressed;aria-label:row.label"
                        data-p-on="mousedown.prevent:swallow;click:toggleSetting"
                      ></button>
                    </div>
                    <!-- select: native dropdown. \`selected\` rides the option (correct
                     initial pick even before the select's value bind applies);
                     \`value\` on the select re-applies on later model changes. -->
                    <label class="block" data-p-show="row.isSelect">
                      <span
                        class="mb-1 block text-[13px] font-medium text-neutral-700"
                        data-p-text="row.label"
                      ></span>
                      <select
                        class="h-10 w-full cursor-pointer rounded-xs border border-neutral-300 bg-white px-2 text-[13px] focus-visible:border-[var(--color-accent)] focus-visible:outline-none"
                        data-p-bind="data-id:row.id;data-key:row.key;data-setting:row.setting;value:row.value"
                        data-p-on="change:applyInputSetting"
                      >
                        <template data-p-for="opt of row.options" data-p-key="opt.value">
                          <option
                            data-p-bind="value:opt.value;selected:opt.pressed"
                            data-p-text="opt.label"
                          ></option>
                        </template>
                      </select>
                    </label>
                    <!-- text -->
                    <label class="block" data-p-show="row.isText">
                      <span
                        class="mb-1 block text-[13px] font-medium text-neutral-700"
                        data-p-text="row.label"
                      ></span>
                      <input
                        type="text"
                        class="h-10 w-full rounded-xs border border-neutral-300 bg-white px-2 text-[13px] focus-visible:border-[var(--color-accent)] focus-visible:outline-none"
                        data-p-bind="data-id:row.id;data-key:row.key;data-setting:row.setting;data-field:row.field;value:row.value;placeholder:row.placeholder"
                        data-p-on="change:applyInputSetting"
                      />
                    </label>
                    <!-- number: min/max/step ride only when declared (null unbinds) -->
                    <label class="block" data-p-show="row.isNumber">
                      <span
                        class="mb-1 block text-[13px] font-medium text-neutral-700"
                        data-p-text="row.label"
                      ></span>
                      <input
                        type="number"
                        data-kind="number"
                        class="h-10 w-full rounded-xs border border-neutral-300 bg-white px-2 text-[13px] focus-visible:border-[var(--color-accent)] focus-visible:outline-none"
                        data-p-bind="data-id:row.id;data-key:row.key;data-setting:row.setting;value:row.value;min:row.min;max:row.max;step:row.step;aria-invalid:row.invalid"
                        data-p-on="change:applyInputSetting"
                      />
                    </label>
                    <!-- media (sidebar shape): "Add image" when empty,
                     thumbnail + Replace/Remove when set, then ALT TEXT.
                     URL insertion lives in the canvas placeholder card. -->
                    <div data-p-show="row.isMedia">
                      <span
                        class="mb-2 block text-[13px] font-medium text-neutral-700"
                        data-p-text="row.label"
                      ></span>
                      <div
                        class="mb-2 flex items-center gap-2 rounded-xs border border-neutral-200 px-3 py-2.5 text-[13px] font-medium text-neutral-500"
                        role="status"
                        data-p-show="row.mediaBusy"
                      >
                        <svg
                          class="h-4 w-4 animate-spin"
                          viewBox="0 0 24 24"
                          fill="none"
                          aria-hidden="true"
                        >
                          <circle
                            cx="12"
                            cy="12"
                            r="9"
                            stroke="currentColor"
                            stroke-opacity="0.25"
                            stroke-width="2.5"
                          />
                          <path
                            d="M21 12a9 9 0 0 0-9-9"
                            stroke="currentColor"
                            stroke-width="2.5"
                            stroke-linecap="round"
                          />
                        </svg>
                        <span data-p-text="row.mediaBusyLabel"></span>
                      </div>
                      <label
                        class="mb-2 flex w-full cursor-pointer items-center justify-center rounded-xs border border-neutral-300 px-3 py-2.5 text-[13px] font-medium text-neutral-900 hover:border-neutral-400"
                        data-p-show="row.showAdd"
                      >
                        <span data-p-text="row.addLabel"></span>
                        <input
                          type="file"
                          class="hidden"
                          data-p-bind="data-id:row.id;data-field:row.field;data-key:row.key"
                          data-p-on="change:uploadMedia"
                        />
                      </label>
                      <button
                        type="button"
                        class="mb-2 flex w-full cursor-pointer items-center justify-center rounded-xs border border-neutral-300 px-3 py-2.5 text-[13px] font-medium text-neutral-900 hover:border-neutral-400"
                        data-p-show="row.showBrowseEmpty"
                        data-p-bind="data-id:row.id;data-field:row.field;data-key:row.key"
                        data-p-on="mousedown.prevent:swallow;click:browseMedia"
                      >
                        Media Library
                      </button>
                      <div data-p-show="row.hasMedia">
                        <img
                          alt=""
                          class="mb-2 max-h-32 w-full rounded-xs bg-neutral-100 object-contain"
                          data-p-bind="src:row.mediaSrc"
                        />
                        <div class="mb-2 flex items-center gap-1.5" data-p-show="row.mediaIdle">
                          <label
                            class="inline-flex h-10 cursor-pointer items-center rounded-xs border border-neutral-300 px-3 text-[13px] font-medium hover:border-neutral-400"
                            data-p-show="row.canUpload"
                          >
                            Replace
                            <input
                              type="file"
                              class="hidden"
                              data-p-bind="data-id:row.id;data-field:row.field;data-key:row.key"
                              data-p-on="change:uploadMedia"
                            />
                          </label>
                          <button
                            type="button"
                            class="inline-flex h-10 cursor-pointer items-center rounded-xs border border-neutral-300 px-3 text-[13px] font-medium hover:border-neutral-400"
                            data-p-show="row.showBrowse"
                            data-p-bind="data-id:row.id;data-field:row.field;data-key:row.key"
                            data-p-on="mousedown.prevent:swallow;click:browseMedia"
                          >
                            Media Library
                          </button>
                          <button
                            type="button"
                            class="h-10 cursor-pointer rounded-xs px-2 text-[13px] font-medium text-neutral-500 hover:text-neutral-900"
                            data-p-bind="data-id:row.id;data-field:row.field"
                            data-p-on="mousedown.prevent:swallow;click:clearMedia"
                          >
                            Remove
                          </button>
                        </div>
                      </div>
                      <span
                        class="mt-2 mb-1 block text-[11px] font-semibold tracking-wide text-neutral-700 uppercase"
                        >Alternative text</span
                      >
                      <textarea
                        rows="3"
                        class="w-full resize-y rounded-xs border border-neutral-300 bg-white px-2 py-1.5 text-[13px] focus-visible:border-[var(--color-accent)] focus-visible:outline-none"
                        aria-label="Alternative text"
                        data-p-bind="data-id:row.id;data-field:row.field;value:row.mediaAlt"
                        data-p-on="change:applyMediaAlt"
                      ></textarea>
                      <span class="mt-1 block text-xs text-neutral-500"
                        >Describe the purpose of the media. Leave empty if decorative.</span
                      >
                    </div>
                    <p
                      class="mt-2 mb-0 text-xs leading-relaxed text-red-600"
                      role="alert"
                      data-p-show="row.error"
                      data-p-text="row.error"
                    ></p>
                    <p
                      class="mt-2 mb-0 text-xs leading-relaxed text-neutral-500"
                      data-p-show="row.help"
                      data-p-text="row.help"
                    ></p>
                  </div>
                </div>
              </template>
            </div>

            <div id="block-styles" class="hidden" data-p-show="blockInspectorTab|eq|styles">
              <div class="flex h-11 items-center justify-between border-b border-neutral-200">
                <span class="text-[13px] font-semibold text-neutral-900">Block styles</span>
                <div class="relative flex items-center gap-3">
                  <button
                    type="button"
                    class="cursor-pointer text-[12px] font-medium text-neutral-500 hover:text-neutral-900 disabled:cursor-default disabled:opacity-30"
                    data-p-bind="disabled:not:styleHasValues"
                    data-p-on="mousedown.prevent:swallow;click:resetBlockStyles"
                  >
                    Reset all
                  </button>
                  <button
                    type="button"
                    class="flex h-10 w-10 cursor-pointer items-center justify-center rounded-xs text-xl hover:bg-neutral-100"
                    aria-label="Style options"
                    data-p-bind="aria-expanded:styleOptionalOpen;disabled:not:optionalStyleControls.length"
                    data-p-on="mousedown.prevent:swallow;click:toggleStyleOptions"
                  >
                    ⋮
                  </button>
                  <div
                    class="absolute top-10 right-0 z-20 hidden w-56 rounded-xs border border-neutral-300 bg-white p-1 shadow-lg"
                    data-p-show="$styleOptionalOpen"
                  >
                    <span
                      class="block px-2 py-1.5 text-[11px] font-semibold tracking-wide text-neutral-500 uppercase"
                      >Optional controls</span
                    >
                    <template
                      data-p-for="control of $optionalStyleControls"
                      data-p-key="control.prop"
                    >
                      <button
                        type="button"
                        class="flex h-10 w-full cursor-pointer items-center justify-between rounded-xs px-2 text-left text-[13px] hover:bg-neutral-100 aria-pressed:bg-neutral-100"
                        data-p-bind="data-prop:control.prop;aria-pressed:control.enabled"
                        data-p-on="mousedown.prevent:swallow;click:toggleOptionalStyle"
                      >
                        <span data-p-text="control.label"></span>
                        <span data-p-show="control.enabled">✓</span>
                      </button>
                    </template>
                  </div>
                </div>
              </div>
              <!-- Unresolved utilities (E4): utility-shaped classes on this
               block whose token the theme lacks — Define… jumps to the Design
               tab prefilled (the paste-a-Tailwind-template onboarding loop). -->
              <div
                class="mt-6 rounded-xs border border-amber-300 bg-amber-50 p-3"
                data-p-show="$unresolvedChips.length"
              >
                <span class="mb-2 block text-[11px] font-semibold text-amber-900"
                  >Not in your theme</span
                >
                <template data-p-for="chip of $unresolvedChips" data-p-key="chip.cls">
                  <div class="mb-1.5 flex items-center justify-between gap-2 last:mb-0">
                    <code
                      class="truncate text-[11px] text-amber-900"
                      data-p-text="chip.cls"
                      data-p-bind="title:chip.label"
                    ></code>
                    <button
                      type="button"
                      class="shrink-0 cursor-pointer rounded-xs border border-amber-400 px-2 py-0.5 text-[11px] font-semibold text-amber-900 hover:bg-amber-100"
                      data-p-bind="data-ns:chip.ns;data-suffix:chip.suffix"
                      data-p-on="mousedown.prevent:swallow;click:defineFromChip"
                    >
                      Define…
                    </button>
                  </div>
                </template>
              </div>

              <!-- Universal STYLE controls (Phase C), grouped into panels
               (Styles / Typography / Color / Dimensions / Border). Shown per
               the block's supports/variations; values via editor.setStyle,
               disabled when policy isn't stylable. The control vocabulary:
               segmented scales (equal columns, internal dividers, active =
               solid dark), filled color swatches (inset ring keeps light
               colors legible), and the variation grid with a Default chip. -->

              <!-- Styles (C6): Default + named variations -->
              <details
                open
                class="border-t border-neutral-200 py-5"
                data-p-show="$variationOptions.length"
              >
                <summary
                  class="mb-4 flex cursor-pointer list-none items-center justify-between [&::-webkit-details-marker]:hidden"
                >
                  <span class="block text-[15px] font-semibold text-neutral-900">Styles</span>
                  <button
                    type="button"
                    data-panel="styles"
                    class="cursor-pointer text-[11px] font-medium text-neutral-500 hover:text-neutral-900"
                    data-p-on="mousedown.prevent:swallow;click.stop:resetStylePanel"
                  >
                    Reset
                  </button>
                </summary>
                <div class="grid grid-cols-2 gap-2" role="group" aria-label="Styles">
                  <template data-p-for="v of $variationOptions" data-p-key="v.name">
                    <button
                      type="button"
                      class="flex h-10 cursor-pointer items-center justify-center rounded-xs border border-neutral-300 bg-white px-2 text-[13px] font-medium text-neutral-900 hover:border-neutral-400 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none aria-pressed:border-neutral-900 aria-pressed:bg-neutral-900 aria-pressed:text-white disabled:cursor-default disabled:opacity-40"
                      data-p-bind="data-name:v.name;aria-pressed:v.pressed;disabled:$styleDisabled;aria-label:v.label"
                      data-p-on="mousedown.prevent:swallow;click:applyVariation"
                      data-p-text="v.label"
                    ></button>
                  </template>
                </div>
              </details>

              <!-- Typography (C1 font size + C5 extras) -->
              <details
                open
                class="border-t border-neutral-200 py-5"
                data-p-show="$styleFontSizeShown"
              >
                <summary
                  class="mb-4 flex cursor-pointer list-none items-center justify-between [&::-webkit-details-marker]:hidden"
                >
                  <span class="block text-[15px] font-semibold text-neutral-900">Typography</span>
                  <button
                    type="button"
                    data-panel="typography"
                    class="cursor-pointer text-[11px] font-medium text-neutral-500 hover:text-neutral-900"
                    data-p-on="mousedown.prevent:swallow;click.stop:resetStylePanel"
                  >
                    Reset
                  </button>
                </summary>
                <span class="mb-1.5 block text-[12px] text-neutral-500">Font size</span>
                <div
                  class="flex overflow-hidden rounded-xs border border-neutral-300"
                  role="group"
                  aria-label="Font size"
                  data-p-show="not:fontSizeIsSelect"
                >
                  <template data-p-for="opt of $fontSizeOptions" data-p-key="opt.key">
                    <button
                      type="button"
                      class="flex h-10 flex-1 cursor-pointer items-center justify-center border-r border-neutral-300 bg-white text-[13px] font-medium text-neutral-700 last:border-r-0 hover:bg-neutral-50 focus-visible:relative focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none aria-pressed:bg-neutral-900 aria-pressed:text-white disabled:cursor-default disabled:opacity-40"
                      data-p-bind="data-key:opt.key;aria-pressed:opt.pressed;disabled:$styleDisabled;aria-label:opt.label"
                      data-p-on="mousedown.prevent:swallow;click:applyFontSize"
                      data-p-text="opt.label"
                    ></button>
                  </template>
                </div>
                <select
                  class="h-10 w-full cursor-pointer rounded-xs border border-neutral-300 bg-white px-2 text-[13px] font-medium text-neutral-700 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none disabled:cursor-default disabled:opacity-40"
                  aria-label="Font size"
                  data-prop="fontSize"
                  data-p-show="$fontSizeIsSelect"
                  data-p-bind="disabled:$styleDisabled"
                  data-p-on="change:applyStyleSelect"
                >
                  <option value="">Default</option>
                  <template data-p-for="opt of $fontSizeOptions" data-p-key="opt.key">
                    <option
                      data-p-bind="value:opt.key;selected:opt.pressed"
                      data-p-text="opt.label"
                    ></option>
                  </template>
                </select>
                <details class="pbe-custom-value">
                  <summary>Custom value</summary>
                  <input
                    type="text"
                    placeholder="For example 17px"
                    aria-label="Custom font size"
                    data-prop="fontSize"
                    data-p-bind="value:$fontSizeValue;disabled:$styleDisabled"
                    data-p-on="change:applyStyleInput"
                  />
                </details>
                <template data-p-for="row of $typographyRows" data-p-key="row.prop">
                  <div class="mt-4">
                    <span
                      class="mb-1.5 block text-[12px] text-neutral-500"
                      data-p-text="row.label"
                    ></span>
                    <div
                      class="flex overflow-hidden rounded-xs border border-neutral-300"
                      role="group"
                      data-p-bind="aria-label:row.label"
                      data-p-show="row.isSegmented"
                    >
                      <template data-p-for="opt of row.options" data-p-key="opt.key">
                        <button
                          type="button"
                          class="flex h-10 flex-1 cursor-pointer items-center justify-center border-r border-neutral-300 bg-white text-[13px] font-medium text-neutral-700 last:border-r-0 hover:bg-neutral-50 focus-visible:relative focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none aria-pressed:bg-neutral-900 aria-pressed:text-white disabled:cursor-default disabled:opacity-40"
                          data-p-bind="data-prop:row.prop;data-key:opt.key;aria-pressed:opt.pressed;disabled:$styleDisabled;aria-label:opt.label"
                          data-p-on="mousedown.prevent:swallow;click:applyDimension"
                          data-p-text="opt.label"
                        ></button>
                      </template>
                    </div>
                    <div class="pbe-scale pbe-scale--editable" data-p-show="row.isRange">
                      <div class="pbe-scale__track" aria-hidden="true">
                        <template data-p-for="opt of row.options" data-p-key="opt.key"
                          ><span></span
                        ></template>
                      </div>
                      <input
                        type="range"
                        min="0"
                        step="1"
                        class="pbe-scale__input"
                        data-p-bind="data-prop:row.prop;max:row.rangeMax;value:row.rangeIndex;disabled:$styleDisabled;aria-label:row.label"
                        data-p-on="change:applyStyleRange"
                      />
                      <input
                        type="text"
                        class="pbe-scale__editor"
                        placeholder="Default"
                        data-p-bind="data-prop:row.prop;value:row.value;disabled:$styleDisabled;aria-label:row.label"
                        data-p-on="change:applyStyleInput"
                      />
                    </div>
                    <select
                      class="h-10 w-full cursor-pointer rounded-xs border border-neutral-300 bg-white px-2 text-[13px] font-medium text-neutral-700 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none disabled:cursor-default disabled:opacity-40"
                      data-p-show="row.isSelect"
                      data-p-bind="data-prop:row.prop;aria-label:row.label;disabled:$styleDisabled"
                      data-p-on="change:applyStyleSelect"
                    >
                      <option value="">Default</option>
                      <template data-p-for="opt of row.options" data-p-key="opt.key">
                        <option
                          data-p-bind="value:opt.key;selected:opt.pressed"
                          data-p-text="opt.label"
                        ></option>
                      </template>
                    </select>
                    <details class="pbe-custom-value" data-p-show="row.showCustomDisclosure">
                      <summary>Custom value</summary>
                      <input
                        type="text"
                        placeholder="Token step or CSS value"
                        data-p-bind="data-prop:row.prop;value:row.value;aria-label:row.label;disabled:$styleDisabled"
                        data-p-on="change:applyStyleInput"
                      />
                    </details>
                  </div>
                </template>
              </details>

              <!-- Color (C2): Text / Background swatch rows -->
              <details
                open
                class="border-t border-neutral-200 py-5"
                data-p-show="$colorRows.length"
              >
                <summary
                  class="mb-4 flex cursor-pointer list-none items-center justify-between [&::-webkit-details-marker]:hidden"
                >
                  <span class="block text-[15px] font-semibold text-neutral-900">Color</span>
                  <button
                    type="button"
                    data-panel="color"
                    class="cursor-pointer text-[11px] font-medium text-neutral-500 hover:text-neutral-900"
                    data-p-on="mousedown.prevent:swallow;click.stop:resetStylePanel"
                  >
                    Reset
                  </button>
                </summary>
                <template data-p-for="row of $colorRows" data-p-key="row.prop">
                  <div class="mt-4 first:mt-0">
                    <div class="mb-1.5 flex items-center justify-between">
                      <span class="text-[12px] text-neutral-500" data-p-text="row.label"></span>
                      <button
                        type="button"
                        class="cursor-pointer text-[11px] font-medium text-neutral-500 hover:text-neutral-900 disabled:opacity-40"
                        data-p-bind="data-prop:row.prop;disabled:$styleDisabled"
                        data-p-on="mousedown.prevent:swallow;click:applyColor"
                        data-p-show="row.value"
                      >
                        Clear
                      </button>
                    </div>
                    <div
                      class="flex flex-wrap gap-2"
                      role="group"
                      data-p-bind="aria-label:row.label"
                      data-p-show="not:row.grid"
                    >
                      <template data-p-for="sw of row.swatches" data-p-key="sw.key">
                        <button
                          type="button"
                          class="h-7 w-7 cursor-pointer rounded-full shadow-[inset_0_0_0_1px_rgba(0,0,0,0.15)] transition-transform hover:scale-110 focus-visible:shadow-[inset_0_0_0_1px_rgba(0,0,0,0.15),0_0_0_2px_#fff,0_0_0_4px_var(--color-accent)] focus-visible:outline-none disabled:cursor-default disabled:opacity-40 aria-pressed:shadow-[inset_0_0_0_1px_rgba(0,0,0,0.15),0_0_0_2px_#fff,0_0_0_4px_var(--color-accent)]"
                          data-p-style="background-color->sw.css"
                          data-p-bind="data-prop:row.prop;data-value:sw.key;aria-pressed:sw.pressed;disabled:$styleDisabled;aria-label:sw.label;title:sw.label"
                          data-p-on="mousedown.prevent:swallow;click:applyColor"
                        ></button>
                      </template>
                    </div>
                    <!-- Big palettes (the full Tailwind default: 22 families ×
                     11 steps) render as a family grid of small dots. -->
                    <div
                      class="flex flex-col gap-1"
                      role="group"
                      data-p-bind="aria-label:row.label"
                      data-p-show="row.grid"
                    >
                      <template data-p-for="fam of row.families" data-p-key="fam.family">
                        <div class="flex items-center gap-1">
                          <template data-p-for="sw of fam.swatches" data-p-key="sw.key">
                            <button
                              type="button"
                              class="h-4 w-4 cursor-pointer rounded-full shadow-[inset_0_0_0_1px_rgba(0,0,0,0.15)] transition-transform hover:scale-125 focus-visible:shadow-[inset_0_0_0_1px_rgba(0,0,0,0.15),0_0_0_2px_var(--color-accent)] focus-visible:outline-none disabled:cursor-default disabled:opacity-40 aria-pressed:shadow-[inset_0_0_0_1px_rgba(0,0,0,0.15),0_0_0_1.5px_#fff,0_0_0_3px_var(--color-accent)]"
                              data-p-style="background-color->sw.css"
                              data-p-bind="data-prop:row.prop;data-value:sw.key;aria-pressed:sw.pressed;disabled:$styleDisabled;aria-label:sw.label;title:sw.label"
                              data-p-on="mousedown.prevent:swallow;click:applyColor"
                            ></button>
                          </template>
                        </div>
                      </template>
                    </div>
                  </div>
                </template>
              </details>

              <!-- Dimensions: Webflow-style box model + token scales. -->
              <details
                id="block-dimensions"
                open
                class="border-t border-neutral-200 py-5"
                data-p-show="$dimensionPanelShown"
              >
                <summary
                  class="mb-4 flex cursor-pointer list-none items-center justify-between [&::-webkit-details-marker]:hidden"
                >
                  <span class="block text-[15px] font-semibold text-neutral-900">Dimensions</span>
                  <button
                    type="button"
                    data-panel="spacing,dimensions"
                    class="cursor-pointer text-[11px] font-medium text-neutral-500 hover:text-neutral-900"
                    data-p-on="mousedown.prevent:swallow;click.stop:resetStylePanel"
                  >
                    Reset
                  </button>
                </summary>
                <div class="pbe-box-model mb-5" data-p-show="$spacingBoxShown">
                  <div class="pbe-box-model__layer pbe-box-model__margin">
                    <span class="pbe-box-model__label">Margin</span>
                    <button
                      type="button"
                      data-kind="margin"
                      class="pbe-box-model__link"
                      data-p-show="$boxMarginShown"
                      data-p-bind="disabled:$styleDisabled;aria-label:marginSidesLabel;title:marginSidesLabel;aria-pressed:marginSidesLinked"
                      data-p-on="mousedown.prevent:swallow;click:toggleSpacingSides"
                    >
                      <svg aria-hidden="true" class="h-4 w-4" viewBox="0 0 24 24">
                        <g
                          fill="none"
                          stroke="currentColor"
                          stroke-width="1.5"
                          stroke-linecap="round"
                          stroke-linejoin="round"
                        >
                          <path
                            d="M13.75 10.25a3.5 3.5 0 0 1 0 4.95l-2.55 2.55a3.5 3.5 0 0 1-4.95-4.95l1.3-1.3"
                          />
                          <path
                            d="M10.25 13.75a3.5 3.5 0 0 1 0-4.95l2.55-2.55a3.5 3.5 0 0 1 4.95 4.95l-1.3 1.3"
                          />
                        </g>
                      </svg>
                    </button>
                    <button
                      type="button"
                      class="pbe-box-model__value"
                      data-kind="margin"
                      data-side="Top"
                      data-position="Top"
                      aria-label="Edit margin top"
                      data-p-show="$boxMarginShown"
                      data-p-bind="aria-pressed:boxActiveKey|eq|margin-Top;disabled:$styleDisabled"
                      data-p-on="mousedown.prevent:swallow;click:selectBoxSide"
                      data-p-text="$boxMarginTop"
                    ></button>
                    <button
                      type="button"
                      class="pbe-box-model__value"
                      data-kind="margin"
                      data-side="Right"
                      data-position="Right"
                      aria-label="Edit margin right"
                      data-p-show="$boxMarginShown"
                      data-p-bind="aria-pressed:boxActiveKey|eq|margin-Right;disabled:$styleDisabled"
                      data-p-on="mousedown.prevent:swallow;click:selectBoxSide"
                      data-p-text="$boxMarginRight"
                    ></button>
                    <button
                      type="button"
                      class="pbe-box-model__value"
                      data-kind="margin"
                      data-side="Bottom"
                      data-position="Bottom"
                      aria-label="Edit margin bottom"
                      data-p-show="$boxMarginShown"
                      data-p-bind="aria-pressed:boxActiveKey|eq|margin-Bottom;disabled:$styleDisabled"
                      data-p-on="mousedown.prevent:swallow;click:selectBoxSide"
                      data-p-text="$boxMarginBottom"
                    ></button>
                    <button
                      type="button"
                      class="pbe-box-model__value"
                      data-kind="margin"
                      data-side="Left"
                      data-position="Left"
                      aria-label="Edit margin left"
                      data-p-show="$boxMarginShown"
                      data-p-bind="aria-pressed:boxActiveKey|eq|margin-Left;disabled:$styleDisabled"
                      data-p-on="mousedown.prevent:swallow;click:selectBoxSide"
                      data-p-text="$boxMarginLeft"
                    ></button>
                    <div class="pbe-box-model__layer pbe-box-model__padding">
                      <span class="pbe-box-model__label">Padding</span>
                      <button
                        type="button"
                        data-kind="padding"
                        class="pbe-box-model__link"
                        data-p-show="$boxPaddingShown"
                        data-p-bind="disabled:$styleDisabled;aria-label:paddingSidesLabel;title:paddingSidesLabel;aria-pressed:paddingSidesLinked"
                        data-p-on="mousedown.prevent:swallow;click:toggleSpacingSides"
                      >
                        <svg aria-hidden="true" class="h-4 w-4" viewBox="0 0 24 24">
                          <g
                            fill="none"
                            stroke="currentColor"
                            stroke-width="1.5"
                            stroke-linecap="round"
                            stroke-linejoin="round"
                          >
                            <path
                              d="M13.75 10.25a3.5 3.5 0 0 1 0 4.95l-2.55 2.55a3.5 3.5 0 0 1-4.95-4.95l1.3-1.3"
                            />
                            <path
                              d="M10.25 13.75a3.5 3.5 0 0 1 0-4.95l2.55-2.55a3.5 3.5 0 0 1 4.95 4.95l-1.3 1.3"
                            />
                          </g>
                        </svg>
                      </button>
                      <button
                        type="button"
                        class="pbe-box-model__value"
                        data-kind="padding"
                        data-side="Top"
                        data-position="Top"
                        aria-label="Edit padding top"
                        data-p-show="$boxPaddingShown"
                        data-p-bind="aria-pressed:boxActiveKey|eq|padding-Top;disabled:$styleDisabled"
                        data-p-on="mousedown.prevent:swallow;click:selectBoxSide"
                        data-p-text="$boxPaddingTop"
                      ></button>
                      <button
                        type="button"
                        class="pbe-box-model__value"
                        data-kind="padding"
                        data-side="Right"
                        data-position="Right"
                        aria-label="Edit padding right"
                        data-p-show="$boxPaddingShown"
                        data-p-bind="aria-pressed:boxActiveKey|eq|padding-Right;disabled:$styleDisabled"
                        data-p-on="mousedown.prevent:swallow;click:selectBoxSide"
                        data-p-text="$boxPaddingRight"
                      ></button>
                      <button
                        type="button"
                        class="pbe-box-model__value"
                        data-kind="padding"
                        data-side="Bottom"
                        data-position="Bottom"
                        aria-label="Edit padding bottom"
                        data-p-show="$boxPaddingShown"
                        data-p-bind="aria-pressed:boxActiveKey|eq|padding-Bottom;disabled:$styleDisabled"
                        data-p-on="mousedown.prevent:swallow;click:selectBoxSide"
                        data-p-text="$boxPaddingBottom"
                      ></button>
                      <button
                        type="button"
                        class="pbe-box-model__value"
                        data-kind="padding"
                        data-side="Left"
                        data-position="Left"
                        aria-label="Edit padding left"
                        data-p-show="$boxPaddingShown"
                        data-p-bind="aria-pressed:boxActiveKey|eq|padding-Left;disabled:$styleDisabled"
                        data-p-on="mousedown.prevent:swallow;click:selectBoxSide"
                        data-p-text="$boxPaddingLeft"
                      ></button>
                      <div class="pbe-box-model__content">Content</div>
                    </div>
                  </div>
                  <div class="pbe-box-model__control">
                    <span class="pbe-box-model__control-label" data-p-text="$boxActiveLabel"></span>
                    <div class="pbe-scale pbe-scale--editable">
                      <div class="pbe-scale__track" aria-hidden="true">
                        <template data-p-for="opt of $boxSpacingOptions" data-p-key="opt.key"
                          ><span></span
                        ></template>
                      </div>
                      <input
                        type="range"
                        min="0"
                        step="1"
                        class="pbe-scale__input"
                        data-p-bind="max:boxActiveRangeMax;value:boxActiveRangeIndex;disabled:$styleDisabled;aria-label:boxActiveLabel"
                        data-p-on="change:applyBoxScale"
                      />
                      <input
                        type="text"
                        class="pbe-scale__editor"
                        placeholder="Default"
                        data-p-bind="data-kind:boxActiveKind;data-side:boxActiveSide;value:boxActiveValue;disabled:$styleDisabled;aria-label:boxActiveLabel"
                        data-p-on="change:applyBoxSpacing"
                      />
                    </div>
                  </div>
                </div>
                <template data-p-for="row of $dimensionRows" data-p-key="row.prop">
                  <div class="mt-4 first:mt-0">
                    <span
                      class="mb-1.5 block text-[12px] text-neutral-500"
                      data-p-text="row.label"
                    ></span>
                    <div
                      class="flex overflow-hidden rounded-xs border border-neutral-300"
                      role="group"
                      data-p-bind="aria-label:row.label"
                      data-p-show="row.isSegmented"
                    >
                      <template data-p-for="opt of row.options" data-p-key="opt.key">
                        <button
                          type="button"
                          class="flex h-10 flex-1 cursor-pointer items-center justify-center border-r border-neutral-300 bg-white text-[13px] font-medium text-neutral-700 last:border-r-0 hover:bg-neutral-50 focus-visible:relative focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none aria-pressed:bg-neutral-900 aria-pressed:text-white disabled:cursor-default disabled:opacity-40"
                          data-p-bind="data-prop:row.prop;data-key:opt.key;aria-pressed:opt.pressed;disabled:$styleDisabled;aria-label:opt.label"
                          data-p-on="mousedown.prevent:swallow;click:applyDimension"
                          data-p-text="opt.label"
                        ></button>
                      </template>
                    </div>
                    <div class="pbe-scale pbe-scale--editable" data-p-show="row.isRange">
                      <div class="pbe-scale__track" aria-hidden="true">
                        <template data-p-for="opt of row.options" data-p-key="opt.key"
                          ><span></span
                        ></template>
                      </div>
                      <input
                        type="range"
                        min="0"
                        step="1"
                        class="pbe-scale__input"
                        data-p-bind="data-prop:row.prop;max:row.rangeMax;value:row.rangeIndex;disabled:$styleDisabled;aria-label:row.label"
                        data-p-on="change:applyStyleRange"
                      />
                      <input
                        type="text"
                        class="pbe-scale__editor"
                        placeholder="Default"
                        data-p-bind="data-prop:row.prop;value:row.value;disabled:$styleDisabled;aria-label:row.label"
                        data-p-on="change:applyStyleInput"
                      />
                    </div>
                    <select
                      class="h-10 w-full cursor-pointer rounded-xs border border-neutral-300 bg-white px-2 text-[13px] focus-visible:border-[var(--color-accent)] focus-visible:outline-none"
                      data-p-show="row.isSelect"
                      data-p-bind="data-prop:row.prop;aria-label:row.label;disabled:$styleDisabled"
                      data-p-on="change:applyStyleSelect"
                    >
                      <option value="">Default</option>
                      <template data-p-for="opt of row.options" data-p-key="opt.key">
                        <option
                          data-p-bind="value:opt.key;selected:opt.pressed"
                          data-p-text="opt.label"
                        ></option>
                      </template>
                    </select>
                    <details class="pbe-custom-value" data-p-show="row.showCustomDisclosure">
                      <summary>Custom value</summary>
                      <input
                        type="text"
                        placeholder="Token step or CSS value"
                        data-p-bind="data-prop:row.prop;value:row.value;aria-label:row.label;disabled:$styleDisabled"
                        data-p-on="change:applyStyleInput"
                      />
                    </details>
                  </div>
                </template>
              </details>

              <details
                open
                class="border-t border-neutral-200 py-5"
                data-p-show="$layoutRows.length"
              >
                <summary
                  class="mb-4 flex cursor-pointer list-none items-center justify-between [&::-webkit-details-marker]:hidden"
                >
                  <span class="block text-[15px] font-semibold text-neutral-900">Layout</span>
                  <button
                    type="button"
                    data-panel="layout"
                    class="cursor-pointer text-[11px] font-medium text-neutral-500 hover:text-neutral-900"
                    data-p-on="mousedown.prevent:swallow;click.stop:resetStylePanel"
                  >
                    Reset
                  </button>
                </summary>
                <template data-p-for="row of $layoutRows" data-p-key="row.prop">
                  <div class="mt-4 first:mt-0">
                    <span
                      class="mb-1.5 block text-[12px] text-neutral-500"
                      data-p-text="row.label"
                    ></span>
                    <div
                      class="flex overflow-hidden rounded-xs border border-neutral-300"
                      role="group"
                      data-p-bind="aria-label:row.label"
                      data-p-show="row.isSegmented"
                    >
                      <template data-p-for="opt of row.options" data-p-key="opt.key">
                        <button
                          type="button"
                          class="flex h-10 flex-1 cursor-pointer items-center justify-center border-r border-neutral-300 bg-white px-1 text-[12px] font-medium last:border-r-0 aria-pressed:bg-neutral-900 aria-pressed:text-white"
                          data-p-bind="data-prop:row.prop;data-key:opt.key;aria-pressed:opt.pressed;disabled:$styleDisabled;aria-label:opt.label"
                          data-p-on="mousedown.prevent:swallow;click:applyDimension"
                          data-p-text="opt.label"
                        ></button>
                      </template>
                    </div>
                    <div class="pbe-scale pbe-scale--editable" data-p-show="row.isRange">
                      <div class="pbe-scale__track" aria-hidden="true">
                        <template data-p-for="opt of row.options" data-p-key="opt.key"
                          ><span></span
                        ></template>
                      </div>
                      <input
                        type="range"
                        min="0"
                        step="1"
                        class="pbe-scale__input"
                        data-p-bind="data-prop:row.prop;max:row.rangeMax;value:row.rangeIndex;disabled:$styleDisabled;aria-label:row.label"
                        data-p-on="change:applyStyleRange"
                      />
                      <input
                        type="text"
                        class="pbe-scale__editor"
                        placeholder="Default"
                        data-p-bind="data-prop:row.prop;value:row.value;disabled:$styleDisabled;aria-label:row.label"
                        data-p-on="change:applyStyleInput"
                      />
                    </div>
                    <select
                      class="h-10 w-full cursor-pointer rounded-xs border border-neutral-300 bg-white px-2 text-[13px]"
                      data-p-show="row.isSelect"
                      data-p-bind="data-prop:row.prop;aria-label:row.label;disabled:$styleDisabled"
                      data-p-on="change:applyStyleSelect"
                    >
                      <option value="">Default</option>
                      <template data-p-for="opt of row.options" data-p-key="opt.key">
                        <option
                          data-p-bind="value:opt.key;selected:opt.pressed"
                          data-p-text="opt.label"
                        ></option>
                      </template>
                    </select>
                    <details class="pbe-custom-value" data-p-show="row.showCustomDisclosure">
                      <summary>Custom value</summary>
                      <input
                        type="text"
                        placeholder="Token step or CSS value"
                        data-p-bind="data-prop:row.prop;value:row.value;aria-label:row.label;disabled:$styleDisabled"
                        data-p-on="change:applyStyleInput"
                      />
                    </details>
                  </div>
                </template>
              </details>

              <!-- Border: discrete width/radius scales plus style and color. -->
              <details open class="border-t border-neutral-200 py-5" data-p-show="$borderShown">
                <summary
                  class="mb-4 flex cursor-pointer list-none items-center justify-between [&::-webkit-details-marker]:hidden"
                >
                  <span class="block text-[15px] font-semibold text-neutral-900">Border</span>
                  <button
                    type="button"
                    data-panel="border"
                    class="cursor-pointer text-[11px] font-medium text-neutral-500 hover:text-neutral-900"
                    data-p-on="mousedown.prevent:swallow;click.stop:resetStylePanel"
                  >
                    Reset
                  </button>
                </summary>
                <div class="mb-4" data-p-show="$borderStyleOptions.length">
                  <span class="mb-1.5 block text-[12px] text-neutral-500">Style</span>
                  <div class="flex overflow-hidden rounded-xs border border-neutral-300">
                    <template data-p-for="opt of $borderStyleOptions" data-p-key="opt.key">
                      <button
                        type="button"
                        class="flex h-10 flex-1 cursor-pointer items-center justify-center border-r border-neutral-300 bg-white px-1 text-[11px] font-medium last:border-r-0 aria-pressed:bg-neutral-900 aria-pressed:text-white"
                        data-prop="borderStyle"
                        data-p-bind="data-key:opt.key;aria-pressed:opt.pressed;disabled:$styleDisabled;aria-label:opt.label"
                        data-p-on="mousedown.prevent:swallow;click:applyDimension"
                        data-p-text="opt.label"
                      ></button>
                    </template>
                  </div>
                </div>
                <div data-p-show="$borderWidthOptions.length">
                  <span class="mb-1.5 block text-[12px] text-neutral-500">Width</span>
                  <div class="pbe-scale pbe-scale--editable">
                    <div class="pbe-scale__track" aria-hidden="true">
                      <template data-p-for="opt of $borderWidthOptions" data-p-key="opt.key"
                        ><span></span
                      ></template>
                    </div>
                    <input
                      type="range"
                      min="0"
                      step="1"
                      class="pbe-scale__input"
                      data-prop="borderWidth"
                      aria-label="Border width"
                      data-p-bind="max:borderWidthRangeMax;value:borderWidthRangeIndex;disabled:$styleDisabled"
                      data-p-on="change:applyBorderRange"
                    />
                    <input
                      type="text"
                      class="pbe-scale__editor"
                      placeholder="Default"
                      data-prop="borderWidth"
                      aria-label="Border width"
                      data-p-bind="value:$borderWidthValue;disabled:$styleDisabled"
                      data-p-on="change:applyStyleInput"
                    />
                  </div>
                </div>
                <div class="mt-4" data-p-show="$borderColorShown">
                  <span class="mb-1.5 block text-[12px] text-neutral-500">Color</span>
                  <div
                    class="flex flex-wrap gap-2"
                    role="group"
                    aria-label="Border color"
                    data-p-show="not:borderColorGrid"
                  >
                    <template data-p-for="sw of $borderColorSwatches" data-p-key="sw.key">
                      <button
                        type="button"
                        class="h-7 w-7 cursor-pointer rounded-full shadow-[inset_0_0_0_1px_rgba(0,0,0,0.15)] transition-transform hover:scale-110 focus-visible:shadow-[inset_0_0_0_1px_rgba(0,0,0,0.15),0_0_0_2px_#fff,0_0_0_4px_var(--color-accent)] focus-visible:outline-none disabled:cursor-default disabled:opacity-40 aria-pressed:shadow-[inset_0_0_0_1px_rgba(0,0,0,0.15),0_0_0_2px_#fff,0_0_0_4px_var(--color-accent)]"
                        data-prop="borderColor"
                        data-p-style="background-color->sw.css"
                        data-p-bind="data-value:sw.key;aria-pressed:sw.pressed;disabled:$styleDisabled;aria-label:sw.label;title:sw.label"
                        data-p-on="mousedown.prevent:swallow;click:applyColor"
                      ></button>
                    </template>
                  </div>
                  <div
                    class="flex flex-col gap-1"
                    role="group"
                    aria-label="Border color"
                    data-p-show="$borderColorGrid"
                  >
                    <template data-p-for="fam of $borderColorFamilies" data-p-key="fam.family">
                      <div class="flex items-center gap-1">
                        <template data-p-for="sw of fam.swatches" data-p-key="sw.key">
                          <button
                            type="button"
                            class="h-4 w-4 cursor-pointer rounded-full shadow-[inset_0_0_0_1px_rgba(0,0,0,0.15)] transition-transform hover:scale-125 focus-visible:shadow-[inset_0_0_0_1px_rgba(0,0,0,0.15),0_0_0_2px_var(--color-accent)] focus-visible:outline-none disabled:cursor-default disabled:opacity-40 aria-pressed:shadow-[inset_0_0_0_1px_rgba(0,0,0,0.15),0_0_0_1.5px_#fff,0_0_0_3px_var(--color-accent)]"
                            data-prop="borderColor"
                            data-p-style="background-color->sw.css"
                            data-p-bind="data-value:sw.key;aria-pressed:sw.pressed;disabled:$styleDisabled;aria-label:sw.label;title:sw.label"
                            data-p-on="mousedown.prevent:swallow;click:applyColor"
                          ></button>
                        </template>
                      </div>
                    </template>
                  </div>
                </div>
                <div class="mt-4" data-p-show="$borderRadiusOptions.length">
                  <span class="mb-1.5 block text-[12px] text-neutral-500">Radius</span>
                  <div class="pbe-scale pbe-scale--editable">
                    <div class="pbe-scale__track" aria-hidden="true">
                      <template data-p-for="opt of $borderRadiusOptions" data-p-key="opt.key"
                        ><span></span
                      ></template>
                    </div>
                    <input
                      type="range"
                      min="0"
                      step="1"
                      class="pbe-scale__input"
                      data-prop="borderRadius"
                      aria-label="Border radius"
                      data-p-bind="max:borderRadiusRangeMax;value:borderRadiusRangeIndex;disabled:$styleDisabled"
                      data-p-on="change:applyBorderRange"
                    />
                    <input
                      type="text"
                      class="pbe-scale__editor"
                      placeholder="Default"
                      data-prop="borderRadius"
                      aria-label="Border radius"
                      data-p-bind="value:$borderRadiusValue;disabled:$styleDisabled"
                      data-p-on="change:applyStyleInput"
                    />
                  </div>
                </div>
              </details>
            </div>
          </div>
        </div>

        <!-- Design tab (E4): the visual THEME editor. Sections per token
           namespace; every edit re-installs the theme (editor.setTheme) and
           refreshes canvas CSS + controls. Import/export = v4 @theme CSS. -->
        <div
          id="panel-design"
          class="hidden p-4"
          role="tabpanel"
          data-p-show="sidebarTab|eq|design"
        >
          <!-- Define… banner: landed here from an unresolved chip -->
          <div
            class="mb-4 rounded-xs border border-amber-300 bg-amber-50 p-3"
            data-p-show="$defineShown"
            data-define
          >
            <span class="mb-2 block text-[12px] font-semibold text-amber-900"
              >Define a missing token</span
            >
            <input
              class="mb-1.5 h-8 w-full rounded-xs border border-neutral-300 bg-white px-2 font-mono text-[12px] text-neutral-900 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
              placeholder="token name (e.g. text-xxxxl)"
              aria-label="Token name"
              data-p-bind="value:$defineName"
            />
            <input
              class="h-8 w-full rounded-xs border border-neutral-300 bg-white px-2 font-mono text-[12px] text-neutral-900 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
              placeholder="value (e.g. 6rem)"
              aria-label="Token value"
            />
            <div class="mt-2 flex gap-2">
              <button
                type="button"
                class="h-8 cursor-pointer rounded-xs bg-neutral-900 px-3 text-[12px] font-semibold text-white hover:bg-neutral-800"
                data-p-on="click:designDefine"
              >
                Add token
              </button>
              <button
                type="button"
                class="h-8 cursor-pointer rounded-xs px-3 text-[12px] font-medium text-neutral-600 hover:bg-neutral-100"
                data-p-on="click:defineDismiss"
              >
                Dismiss
              </button>
            </div>
          </div>

          <div class="mb-1 flex items-baseline justify-between">
            <span class="text-[15px] font-semibold text-neutral-900">Theme</span>
          </div>
          <p class="mb-4 text-[11px] text-neutral-500">
            CSS engine: <span data-p-text="$engineLabel"></span>
          </p>

          <div class="mb-2">
            <span class="mb-1.5 block text-[12px] text-neutral-500"
              >Spacing multiplier (--spacing)</span
            >
            <input
              class="h-8 w-full rounded-xs border border-neutral-300 bg-white px-2 font-mono text-[12px] text-neutral-900 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
              aria-label="Spacing multiplier"
              data-p-bind="value:$designSpacing"
              data-p-on="change:designSetSpacing"
            />
          </div>

          <template data-p-for="sec of $designSections" data-p-key="sec.ns">
            <div class="border-t border-neutral-200 py-4">
              <span
                class="mb-2 block text-[13px] font-semibold text-neutral-900"
                data-p-text="sec.label"
              ></span>
              <template data-p-for="row of sec.rows" data-p-key="row.name">
                <div class="mb-1.5 flex items-center gap-2">
                  <span
                    class="h-4 w-4 shrink-0 rounded-full shadow-[inset_0_0_0_1px_rgba(0,0,0,0.15)]"
                    data-p-show="row.isColor"
                    data-p-style="background-color->row.value"
                  ></span>
                  <code
                    class="w-20 shrink-0 truncate text-[11px] text-neutral-600"
                    data-p-text="row.key"
                    data-p-bind="title:row.name"
                  ></code>
                  <input
                    class="h-8 w-full min-w-0 flex-1 rounded-xs border border-neutral-300 bg-white px-2 font-mono text-[11px] text-neutral-900 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
                    data-p-bind="value:row.value;data-name:row.name;aria-label:row.name"
                    data-p-on="change:designUpdateToken"
                  />
                  <button
                    type="button"
                    class="h-6 w-6 shrink-0 cursor-pointer rounded-xs text-[13px] text-neutral-400 hover:bg-neutral-100 hover:text-neutral-900"
                    title="Remove token"
                    data-p-bind="data-name:row.name"
                    data-p-on="click:designRemoveToken"
                  >
                    ×
                  </button>
                </div>
              </template>
              <div class="mt-2 flex items-center gap-2" data-add>
                <input
                  class="h-8 w-20 shrink-0 rounded-xs border border-neutral-300 bg-white px-2 font-mono text-[11px] text-neutral-900 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
                  placeholder="key"
                  aria-label="New token key"
                />
                <input
                  class="h-8 w-full min-w-0 flex-1 rounded-xs border border-neutral-300 bg-white px-2 font-mono text-[11px] text-neutral-900 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
                  placeholder="value"
                  aria-label="New token value"
                />
                <button
                  type="button"
                  class="h-8 shrink-0 cursor-pointer rounded-xs border border-neutral-300 px-2 text-[12px] font-semibold text-neutral-900 hover:border-neutral-400"
                  data-p-bind="data-ns:sec.ns"
                  data-p-on="click:designAddToken"
                >
                  Add
                </button>
              </div>
            </div>
          </template>

          <div class="border-t border-neutral-200 py-4" data-import>
            <span class="mb-2 block text-[13px] font-semibold text-neutral-900"
              >Import Tailwind config</span
            >
            <p class="mb-2 text-[12px] text-neutral-500">
              Paste CSS containing v4 <code>@theme</code> blocks — it becomes this site's theme. (v3
              JS configs: run <code>npx @tailwindcss/upgrade</code> first.)
            </p>
            <textarea
              class="h-24 w-full rounded-xs border border-neutral-300 bg-white p-2 font-mono text-[11px] text-neutral-900 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
              placeholder="@theme { --text-xxxxl: 6rem; }"
              aria-label="Theme CSS to import"
            ></textarea>
            <p
              class="mt-1 text-[11px] text-red-600"
              data-p-show="$designImportError"
              data-p-text="$designImportError"
            ></p>
            <button
              type="button"
              class="mt-2 h-8 cursor-pointer rounded-xs bg-neutral-900 px-3 text-[12px] font-semibold text-white hover:bg-neutral-800"
              data-p-on="click:designImport"
            >
              Import
            </button>
          </div>

          <div class="border-t border-neutral-200 py-4">
            <span class="mb-2 block text-[13px] font-semibold text-neutral-900">Export</span>
            <pre
              class="max-h-48 overflow-auto rounded-xs bg-neutral-50 p-2 font-mono text-[10px] leading-[1.5] text-neutral-700 select-all"
              data-p-text="$designExport"
            ></pre>
          </div>

          <!-- E5 (future): shown only when the engine implements
             classesFromCss — paste CSS, get the equivalent utility classes. -->
          <div
            class="border-t border-neutral-200 py-4"
            data-p-show="$cssImportShown"
            data-css-import
          >
            <span class="mb-2 block text-[13px] font-semibold text-neutral-900">CSS → classes</span>
            <textarea
              class="h-20 w-full rounded-xs border border-neutral-300 bg-white p-2 font-mono text-[11px] text-neutral-900 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
              placeholder="p { font-size: 1.5rem }"
              aria-label="CSS to convert"
            ></textarea>
            <button
              type="button"
              class="mt-2 h-8 cursor-pointer rounded-xs bg-neutral-900 px-3 text-[12px] font-semibold text-white hover:bg-neutral-800"
              data-p-on="click:cssToClasses"
            >
              Convert
            </button>
            <code
              class="mt-2 block text-[11px]"
              data-p-show="$cssImportResult"
              data-p-text="$cssImportResult"
            ></code>
          </div>
        </div>
      </aside>

      <!-- HOST PANELS: extra right sidebars registered via options.panels
         (e.g. a CMS's version history / publish rail). One <aside> per panel,
         appended by shell.ts; visibility is toggled by the matching topbar
         icon in #host-panel-toggles. -->
      <div id="host-panels" class="flex shrink-0"></div>
    </div>

    <!-- Patterns explorer: the full-library dialog behind "Explore all
       patterns" — search + category list left, a grid of live previews
       right. Picking a pattern inserts it and closes the dialog. -->
    <div
      id="pattern-explorer"
      class="fixed inset-0 z-50 flex hidden items-center justify-center bg-black/70 p-4"
      data-p-show="$explorerOpen"
      data-p-on="click:closePatternExplorer;keydown.escape:closePatternExplorer"
    >
      <div
        class="flex h-full w-full flex-col overflow-hidden rounded-xl border border-border bg-background text-foreground shadow-[0_10px_40px_rgb(0_0_0/0.35)]"
        role="dialog"
        aria-modal="true"
        aria-label="Patterns"
        data-p-on="click.stop:swallow"
      >
        <header class="flex shrink-0 items-center justify-between px-6 pt-5 pb-3">
          <h2 class="text-lg font-semibold">Patterns</h2>
          <button
            type="button"
            aria-label="Close patterns explorer"
            class="flex h-9 w-9 cursor-pointer items-center justify-center rounded-xs text-neutral-900 hover:bg-neutral-100 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
            data-p-on="click:closePatternExplorer"
          >
            <svg class="h-6 w-6 fill-current" viewBox="0 0 24 24" aria-hidden="true">
              <g
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path d="M6 6l12 12" />
                <path d="M18 6L6 18" />
              </g>
            </svg>
          </button>
        </header>
        <div class="flex min-h-0 flex-1">
          <div class="w-64 shrink-0 overflow-y-auto px-6 pb-6">
            <input
              id="explorer-search"
              type="text"
              placeholder="Search"
              autocomplete="off"
              aria-label="Search for patterns"
              class="w-full rounded-xs border border-neutral-400 px-3 py-2.5 text-[13px] text-neutral-900 placeholder:text-neutral-500 focus:border-accent focus:shadow-[0_0_0_0.5px_var(--color-accent)] focus:outline-none"
              data-p-model="$explorerQuery|trim"
            />
            <div class="mt-4 flex flex-col gap-0.5">
              <template data-p-for="g of $explorerGroups" data-p-key="g.name">
                <button
                  type="button"
                  class="block w-full cursor-pointer rounded-xs px-3 py-2 text-left text-[13px] font-medium focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
                  data-p-class="g.selected->bg-ui-accent+text-accent-foreground~text-foreground+hover:bg-ui-accent"
                  data-p-bind="data-group:g.name"
                  data-p-on="click:setExplorerGroup"
                >
                  <span data-p-text="g.name"></span>
                </button>
              </template>
            </div>
          </div>
          <div class="flex-1 overflow-y-auto px-6 pb-8">
            <div class="grid grid-cols-[repeat(auto-fill,minmax(420px,1fr))] gap-8">
              <template data-p-for="p of $explorerItems" data-p-key="p.name">
                <div class="explorer-card group self-start">
                  <button
                    type="button"
                    class="group block w-full cursor-pointer text-left focus-visible:outline-none"
                    data-p-bind="data-pattern:p.name;aria-label:p.label"
                    data-p-on="click:explorerPick"
                  >
                    <span
                      class="block w-full overflow-hidden rounded-xs border border-neutral-200 bg-white group-hover:border-accent group-focus-visible:border-accent"
                      data-p-bind="data-pattern-preview:p.name"
                    ></span>
                  </button>
                  <span class="mt-2 flex items-center justify-between">
                    <span class="text-[13px] text-neutral-900" data-p-text="p.label"></span>
                    <!-- tabindex=-1: one focus stop per card (see the flyout note) -->
                    <button
                      type="button"
                      tabindex="-1"
                      class="pattern-edit cursor-pointer rounded-xs px-1.5 py-0.5 text-[11px] font-medium text-neutral-500 hover:bg-neutral-100 hover:text-accent focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none"
                      aria-label="Edit pattern in the library"
                      data-p-bind="data-pattern:p.name"
                      data-p-on="click:editDefinitionFromExplorer"
                    >
                      Edit
                    </button>
                  </span>
                </div>
              </template>
            </div>
            <p class="text-[13px] text-neutral-500" data-p-show="$explorerNoResults">
              No patterns found.
            </p>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>
`;function $o(e){let t=document.createElement(`div`);t.innerHTML=e;let n=new Set;for(let e of t.querySelectorAll(`[class]`))for(let t of e.getAttribute(`class`)?.split(/\s+/)??[])t&&n.add(t);return[...n]}var es=e=>`.${e.replace(/[^a-zA-Z0-9_-]/g,e=>`\\${e.codePointAt(0).toString(16)} `)}`;function ts(e,t=A()){let n=new Map(t.tokens.map(e=>[e.name,e.value])),r=new Map,i=(e,t)=>r.set(e,`${es(e)}{${t}}`);for(let t of e)if(t.startsWith(`text-`)){let e=t.slice(5);n.has(`text-${e}`)?i(t,`font-size:${n.get(`text-${e}`)}`):n.has(`color-${e}`)&&i(t,`color:${n.get(`color-${e}`)}`)}else t.startsWith(`bg-`)&&n.has(`color-${t.slice(3)}`)?i(t,`background-color:${n.get(`color-${t.slice(3)}`)}`):t.startsWith(`border-`)&&n.has(`color-${t.slice(7)}`)?i(t,`border-color:${n.get(`color-${t.slice(7)}`)}`):t.startsWith(`rounded-`)&&n.has(`radius-${t.slice(8)}`)?i(t,`border-radius:${n.get(`radius-${t.slice(8)}`)}`):t.startsWith(`leading-`)&&n.has(`leading-${t.slice(8)}`)?i(t,`line-height:${n.get(`leading-${t.slice(8)}`)}`):t.startsWith(`tracking-`)&&n.has(`tracking-${t.slice(9)}`)&&i(t,`letter-spacing:${n.get(`tracking-${t.slice(9)}`)}`);return[...r.values()].join(`
`)}function ns(e){return{async compile(t,n=A()){let r=await fetch(e,{method:`POST`,body:t.join(` `)});if(!r.ok)throw Error(`css engine: HTTP ${r.status} ${await r.text()}`);return{css:`${await r.text()}\n${ts(t,n)}`,unresolved:Ke(t,n).map(e=>e.cls)}}}}async function rs(e){try{let t=ns(e);return await t.compile([`p-1`]),t}catch{return null}}var is={"top-start":{primary:`top`,align:`start`},top:{primary:`top`,align:`center`},"top-end":{primary:`top`,align:`end`},"bottom-start":{primary:`bottom`,align:`start`},bottom:{primary:`bottom`,align:`center`},"bottom-end":{primary:`bottom`,align:`end`},"left-start":{primary:`left`,align:`start`},left:{primary:`left`,align:`center`},"left-end":{primary:`left`,align:`end`},"right-start":{primary:`right`,align:`start`},right:{primary:`right`,align:`center`},"right-end":{primary:`right`,align:`end`}},as={top:`bottom`,bottom:`top`,left:`right`,right:`left`};function os(e,t,n,r,i){let a,o;return n===`bottom`?a=e.bottom+i:n===`top`?a=e.top-t.height-i:o=n===`left`?e.left-t.width-i:e.right+i,n===`top`||n===`bottom`?o=r===`start`?e.left:r===`end`?e.right-t.width:e.left+(e.width-t.width)/2:a=r===`start`?e.top:r===`end`?e.bottom-t.height:e.top+(e.height-t.height)/2,{top:a,left:o}}function ss(e,t){return e.top<0||e.left<0||e.top+t.height>window.innerHeight||e.left+t.width>window.innerWidth}function cs(e,t,n={}){let r=n.placement||`bottom-start`,i=n.offset??4,a=n.flip!==!1,o=is[r]||is[`bottom-start`],s=t.getBoundingClientRect();e.style.position=`fixed`,e.style.visibility=`hidden`,e.style.top=`0`,e.style.left=`0`;let c=e.getBoundingClientRect();e.style.visibility=``;let{primary:l,align:u}=o,d=os(s,c,l,u,i);if(a&&ss(d,c)){let e=as[l],t=os(s,c,e,u,i);ss(t,c)||(l=e,d=t)}return e.style.top=`${d.top}px`,e.style.left=`${d.left}px`,u===`center`?l:`${l}-${u}`}var ls=null,us=To(!1),ds=document.createElement(`style`);ds.id=`pbe-engine-css`;var fs=null,ps=``,ms={},hs=typeof document>`u`?Promise.resolve():new Promise(e=>{if(document.readyState===`complete`){queueMicrotask(()=>queueMicrotask(()=>e()));return}let t=()=>queueMicrotask(()=>e());document.addEventListener(`DOMContentLoaded`,t,{once:!0}),window.addEventListener(`load`,t,{once:!0})}),gs=620,_s=new Map;function vs(e){let t=_s.get(e);if(t==null){let n=document.createElement(`div`);n.innerHTML=Ot(e)?.content??``,t=ht(ut(n)),_s.set(e,t)}return t}function ys(){for(let e of document.querySelectorAll(`[data-pattern-preview]`)){if(e.dataset.filled)continue;let t=e.dataset.patternPreview;if(!t||!e.clientWidth)continue;e.dataset.filled=`1`;let n=document.createElement(`div`);n.className=`pbe-preview`,n.style.width=`${gs}px`,n.style.transformOrigin=`top left`,n.style.pointerEvents=`none`,n.inert=!0,n.style.fontSize=`15px`,n.style.lineHeight=`1.6`,n.style.display=`flow-root`,n.innerHTML=vs(t);for(let e of n.querySelectorAll(`[data-pb-children]`))e.classList.add(`pbe-container`);e.textContent=``,e.appendChild(n);let r=e.clientWidth/gs;n.style.transform=`scale(${r})`,e.style.height=`${Math.max(48,Math.ceil(n.scrollHeight*r))}px`}}za.store(`dropdown`,()=>{let e=za.reactive({open:!1}),t=null,n=null,r=null,i=()=>n?[...n.querySelectorAll(`[data-publr-part="item"]`)].filter(e=>!e.disabled&&e.getAttribute(`aria-disabled`)!==`true`):[],a=(e,t)=>{e.forEach((e,n)=>e.tabIndex=n===t?0:-1),e[t]?.focus()};return{state:e,actions:{toggle:()=>e.open=!e.open,openMenu:(t,n)=>{n.event.preventDefault(),e.open=!0},close:()=>e.open=!1,navKeys:(t,n)=>{let r=n.event,o=i();if(!o.length)return;let s=o.indexOf(document.activeElement);if(r.key===`ArrowDown`)r.preventDefault(),a(o,s<o.length-1?s+1:0);else if(r.key===`ArrowUp`)r.preventDefault(),a(o,s>0?s-1:o.length-1);else if(r.key===`Home`)r.preventDefault(),a(o,0);else if(r.key===`End`)r.preventDefault(),a(o,o.length-1);else if(r.key===`Enter`||r.key===` `)r.preventDefault(),s>=0&&(o[s].click(),e.open=!1);else if(r.key===`Escape`||r.key===`Tab`)r.preventDefault(),e.open=!1;else if(r.key.length===1&&!r.ctrlKey&&!r.metaKey&&!r.altKey){let e=o.find(e=>e.textContent?.trim().toLowerCase().startsWith(r.key.toLowerCase()));e&&a(o,o.indexOf(e))}},itemClick:(t,n)=>{let r=n.event.target,i=r instanceof Element?r.closest(`[data-publr-part="item"]`):null;i&&!i.disabled&&i.getAttribute(`aria-disabled`)!==`true`&&(e.open=!1)}},setup:({el:o})=>{t=o,n=o.querySelector(`[data-publr-part="content"]`),za.effect(()=>{if(e.open){if(requestAnimationFrame(()=>{if(!e.open||!n||!t)return;cs(n,t,{placement:n.getAttribute(`data-publr-placement`)||`bottom-start`,offset:8});let r=n.querySelector(`[data-publr-autofocus]`);if(r)r.focus();else{let e=i();e.length&&a(e,0)}}),!r){let i=r=>{(!(r.target instanceof Node)||!t?.contains(r.target)&&!n?.contains(r.target))&&(e.open=!1)};document.addEventListener(`mousedown`,i,!0),r=()=>document.removeEventListener(`mousedown`,i,!0)}}else r?.(),r=null})}}}),za.store(`chrome`,()=>{let e=za.reactive({inserterOpen:!1,outputShown:!1,wireEditing:``,wireData:``,sidebarTab:`document`,blockSelected:!1,blockLabel:``,blockIcon:``,blockLetter:``,blockDescription:``,blockSettings:[],blockInspectorTab:`settings`,blockHasStyles:!1,settingSectionOpen:{},settingErrors:{},mediaBusy:{},styleHasValues:!1,styleOptionalOpen:!1,styleOptional:{},styleSidesLinked:{},optionalStyleControls:[],styleFontSizeShown:!1,styleDisabled:!1,fontSizeOptions:[],fontSizeIsSelect:!1,fontSizeValue:``,variationOptions:[],colorRows:[],dimensionRows:[],dimensionPanelShown:!1,spacingBoxShown:!1,boxPaddingShown:!1,boxMarginShown:!1,boxPaddingTop:``,boxPaddingRight:``,boxPaddingBottom:``,boxPaddingLeft:``,boxMarginTop:``,boxMarginRight:``,boxMarginBottom:``,boxMarginLeft:``,boxSpacingOptions:pe.map(e=>({key:e,label:e})),boxActiveKind:`padding`,boxActiveSide:`Top`,boxActiveKey:`padding-Top`,boxActiveLabel:`Padding (all sides)`,boxActiveValue:``,boxActiveRangeIndex:0,boxActiveRangeMax:pe.length,paddingLinkAvailable:!1,paddingSidesLinked:!0,paddingSidesLabel:`Separate sides`,marginLinkAvailable:!1,marginSidesLinked:!0,marginSidesLabel:`Separate sides`,layoutRows:[],borderShown:!1,borderWidthOptions:[],borderWidthRangeIndex:0,borderWidthRangeMax:0,borderWidthValue:``,borderRadiusOptions:[],borderRadiusIsSelect:!1,borderRadiusValue:``,borderRadiusRangeIndex:0,borderRadiusRangeMax:0,borderStyleOptions:[],borderColorShown:!1,borderColorGrid:!1,borderColorValue:``,borderColorSwatches:[],borderColorFamilies:[],typographyRows:[],unresolvedChips:[],engineActive:!1,engineLabel:`probing…`,designSections:[],designSpacing:``,designExport:``,designImportError:``,defineShown:!1,defineName:``,cssImportShown:!1,cssImportResult:``,blockIsPattern:!1,blockPattern:``,blockPatternRoot:``,blockPatternContent:[],templateMode:!1,templateLabel:``,templateIsInstance:!1,templateError:``,emptyNote:`No block selected.`,breadcrumb:`Document`,docEpoch:0,treeOpen:!1,treeTab:`list`,treeRows:[],treeExpanded:{},outlineRows:[],outlineEmpty:!0,docChars:`0`,docWords:`0`,docReadTime:`< 1 minute`,inserterTab:`blocks`,query:``,libraryEpoch:0,shelves:[],noResults:!1,patternQuery:``,patternGroup:``,patternGroups:[],patternFlyoutOpen:!1,patternFlyoutTitle:``,patternItems:[],patternNoResults:!1,explorerOpen:!1,explorerQuery:``,explorerGroup:`All`,explorerGroups:[],explorerItems:[],explorerNoResults:!1}),t,n,r,i=null,a=e=>po(q(e)?.icon??(e===`raw-html`?`html`:void 0)),o=e=>(e[0]??`?`).toUpperCase(),s=e=>rt().find(t=>t.type===e)?.label??(e===`raw-html`?`HTML`:e),c=e=>e.pattern&&Ot(e.pattern)?.label||s(e.type),l=e=>({type:e.type,label:e.label,icon:a(e.type),letter:o(e.type)}),u=(e,t)=>!t||e.type.includes(t)||e.label.toLowerCase().includes(t),d=()=>t.selection.blocks.length>1?null:t.selection.active??(t.selection.blocks.length===1?t.selection.blocks[0]:null),f=null,p=()=>{let e=d();if(e)return f=e,e;let n=document.activeElement;return!n||n===document.body?f&&t.getBlock(f)?f:null:f&&t.getBlock(f)&&n.closest(`[data-pbe-keep-selection]`)?f:(f=null,null)},m=(e,n)=>{let r=t.getBlock(e)?.fields[n];return typeof r==`object`&&r?{src:r.src??``,alt:r.alt??``,width:r.width??``,height:r.height??``}:{src:``,alt:``,width:``,height:``}},h=e=>{let t=document.createElement(`div`);return t.innerHTML=typeof e==`string`?e:``,t.textContent??``};function g(){e.docEpoch;let n=new Set(t.selection.blocks);t.selection.active&&n.add(t.selection.active);let r=[],i=(e,t,r,i)=>({id:e.id,pad:`${4+t*20}px`,icon:e.type===`heading`?po(`heading-level-${h(e.fields.level).replace(/\D/g,``)||`2`}`):e.pattern&&Ot(e.pattern)?a(bt):a(e.type),letter:o(e.type),label:c(e),anchor:e.type===`heading`?h(e.fields.text).trim():``,hasChildren:r,expanded:i,selected:n.has(e.id)}),s=(t,n)=>{for(let a of t){if(a.pattern&&Ot(a.pattern)){let t=Rt(a),o=t.length>0&&!!e.treeExpanded[a.id];if(r.push(i(a,n,t.length>0,o)),o)for(let e of t)r.push(i(e,n+1,!1,!1));continue}let t=!!a.children&&a.children.length>0,o=t&&!!e.treeExpanded[a.id];r.push(i(a,n,t,o)),o&&s(a.children,n+1)}};s(t.getModel().blocks,0),e.treeRows=r}function _(){e.docEpoch;let n=[],r=0,i=0,a=0,o=e=>{i+=e.length,a+=(e.match(/\S+/g)??[]).length};for(let e of _t(t.getModel().blocks)){if(e.type===`raw-html`){o(h(e.fields.html));continue}for(let t of q(e.type)?.fields??[])(t.type===`text`||t.type===`rich`)&&o(h(e.fields[t.name]));if(e.type===`heading`){let t=Number(h(e.fields.level).replace(/\D/g,``))||2,i=h(e.fields.text).trim(),a=r>0&&t>r+1;r=t,n.push({id:e.id,level:`H${t}`,guide:`${(t-1)*20}px`,text:i||`(Empty heading)`,empty:!i,badLevel:a,flagged:!i||a})}}e.docChars=String(i),e.docWords=String(a);let s=Math.round(a/189);e.docReadTime=s<1?`< 1 minute`:`${s} minute${s>1?`s`:``}`,e.outlineRows=n,e.outlineEmpty=n.length===0}let v=null;function y(){if(!v){let e=new Set;for(let t of kt())for(let n of $o(t.content))e.add(n);v=[...e]}return[...new Set([...$o(t.serialize()),...v])]}let b;function x(){fs&&(window.clearTimeout(b),b=window.setTimeout(()=>{fs.compile(y()).then(e=>{ds.textContent=e.css}).catch(e=>console.warn(`[pbe] engine compile failed:`,e))},150))}function S(){let t=A(),n=(e,t,n,r=!1)=>({name:e,key:t,value:n,isColor:r});e.designSections=[{ns:`text`,label:`Font sizes`,rows:ue(t).map(e=>n(`text-${e.key}`,e.key,e.value))},{ns:`color`,label:`Colors`,rows:I(t).map(e=>n(`color-${e.key}`,e.key,e.value,!0))},{ns:`radius`,label:`Radii`,rows:de(t).map(e=>n(`radius-${e.key}`,e.key,e.value))},{ns:`leading`,label:`Line heights`,rows:fe(t).map(e=>n(`leading-${e.key}`,e.key,e.value))},{ns:`tracking`,label:`Letter spacings`,rows:L(t).map(e=>n(`tracking-${e.key}`,e.key,e.value))}],e.designSpacing=R(t)??``,e.designExport=he(t),e.cssImportShown=!!fs?.classesFromCss}function C(e){t.setTheme({tokens:e}),ls?.onThemeCss?.(),x(),S(),w()}function w(){let n=t.selection.blocks.length,r=p(),i=r?t.getBlock(r):null,l=new Set;if(i&&r){let e=vt(t.getModel().blocks,r),n=e?.find(e=>e.pattern&&Ot(e.pattern));n&&n.id!==r&&(i=n,l=new Set(e.map(e=>e.id)))}if(e.blockSelected=!!i,i){let n=q(i.type),u=i.pattern?Ot(i.pattern):void 0,d=t.editingMode(i.id);e.blockIsPattern=!!u,e.blockPattern=u?i.pattern:``,e.blockPatternRoot=u?i.id:``,e.blockPatternContent=u?Rt(i).map(e=>({id:e.id,icon:e.type===`heading`?po(`heading-level-${h(e.fields.level).replace(/\D/g,``)||`2`}`):a(e.type),letter:o(e.type),label:s(e.type),anchor:e.type===`heading`?h(e.fields.text).trim():h(e.fields.body??e.fields.label??``).trim().slice(0,40),selected:l.has(e.id)})):[],e.blockLabel=c(i),e.blockIcon=a(u?bt:i.type),e.blockLetter=u?(u.label[0]??`?`).toUpperCase():o(i.type),e.blockDescription=u?u.description??`A pattern instance. Edits here never change the original design.`:n?.description??``;let f={content:0,structure:1,design:2,advanced:3},p={content:`Content`,structure:`Layout`,design:`Appearance`,advanced:`Advanced`},m=(u?[]:n?.settings??[]).map((e,t)=>{let r=e.field?n?.fields.find(t=>t.name===e.field):null;return{s:e,index:t,role:e.role??(e.transform||r?.type===`tag`?`structure`:e.field?`content`:`advanced`)}}).filter(({role:e})=>d==="default"||e===`content`).filter(({s:e})=>{if(!e.when)return!0;let t=e.when.field?i.fields[e.when.field]:i.settings&&e.when.setting in i.settings?i.settings[e.when.setting]:n?.settings?.find(t=>t.setting===e.when.setting)?.default;return`equals`in e.when?JSON.stringify(t)===JSON.stringify(e.when.equals):JSON.stringify(t)!==JSON.stringify(e.when.notEquals)}).sort((e,t)=>f[e.role]-f[t.role]||e.index-t.index);e.blockSettings=m.map(({s:t,index:n,role:r},a)=>{let o=t.transform?`transform`:t.field?`field`:`setting`,s=o===`setting`&&i.settings&&t.setting in i.settings?i.settings[t.setting]:t.default,c=e=>o===`transform`?i.type===e:o===`field`?i.fields[t.field]===e:s===e,l=t.control===`media`&&t.field?i.fields[t.field]??{}:null,u=typeof s==`string`||typeof s==`number`||typeof s==`boolean`?String(s):``;return{key:`${i.id}:${n}`,id:i.id,label:t.label,mode:o,field:t.field??``,setting:t.setting??``,options:(t.options??[]).map(e=>({value:e.value,label:e.label,icon:po(e.icon),pressed:c(e.value)})),value:o===`setting`?u:o===`field`&&t.control===`text`?h(i.fields[t.field]):``,pressed:s===!0,placeholder:t.placeholder??``,min:t.min??null,max:t.max??null,step:t.step??null,error:e.settingErrors[`${i.id}:${n}`]??``,invalid:!!e.settingErrors[`${i.id}:${n}`],isChoice:t.control===`toggle-group`,isToggle:t.control===`toggle`,isSelect:t.control===`select`,isText:t.control===`text`,isNumber:t.control===`number`,isMedia:t.control===`media`,mediaSrc:l?.src??``,mediaAlt:l?.alt??``,hasMedia:!!l?.src,mediaBusy:!!e.mediaBusy[`${i.id}:${n}`],mediaBusyLabel:e.mediaBusy[`${i.id}:${n}`]??``,mediaIdle:!e.mediaBusy[`${i.id}:${n}`],showAdd:!l?.src&&us.uploadAvailable()&&!e.mediaBusy[`${i.id}:${n}`],addLabel:`Add ${t.label.toLowerCase()}`,canUpload:us.uploadAvailable()&&!e.mediaBusy[`${i.id}:${n}`],showBrowse:!!us.browse&&!e.mediaBusy[`${i.id}:${n}`],showBrowseEmpty:!l?.src&&!!us.browse&&!e.mediaBusy[`${i.id}:${n}`],section:p[r],sectionRole:r,sectionKey:`${i.id}:${r}`,sectionExpanded:e.settingSectionOpen[`${i.id}:${r}`]!==!1,showSection:a===0||m[a-1].role!==r,help:t.help??``}});let g=u||d!=="default"?void 0:t.styleSupports(r),_=u||d!=="default"?void 0:t.blockVariations(r);e.blockHasStyles=!!g||!!_?.length,e.styleHasValues=Object.keys(je).some(e=>!!t.getStyle(r,e))||!!t.getStyle(r,`variation`),!e.blockHasStyles&&e.blockInspectorTab===`styles`&&(e.blockInspectorTab=`settings`);let v=t.getStyle(r,`variation`);e.variationOptions=_?.length?[{name:`default`,label:`Default`,pressed:!v},..._.map(e=>({name:e.name,label:e.label,pressed:e.name===v}))]:[];let y=A(),b=(e,n,i,a,o=!0)=>{let s=t.getStyle(r,e),c=i.map(e=>({...e,pressed:e.key===s})),l=new Set([`padding`,`paddingTop`,`paddingRight`,`paddingBottom`,`paddingLeft`,`margin`,`marginTop`,`marginRight`,`marginBottom`,`marginLeft`,`width`,`height`,`minHeight`,`minWidth`,`flexBasis`,`gap`,`rowGap`,`columnGap`,`gridColumns`,`lineHeight`,`letterSpacing`]).has(e)&&c.length>1;a&&!l&&c.unshift({key:`none`,label:`−`,pressed:!s});let u=c.findIndex(e=>e.key===s)+1;return{prop:e,label:n,options:c,isSelect:!l&&c.length>8,isRange:l,isSegmented:!l&&c.length<=8,rangeIndex:u,rangeMax:c.length,value:s??``,allowCustom:o,showCustomDisclosure:o&&!l}},x=(e,n)=>{let i=t.getStyle(r,e)??``,a=I(y),o=a.map(e=>({key:e.key,css:e.value,label:e.key,pressed:e.key===i})),s=o.length>12,c=[];return s&&a.forEach((e,t)=>{let n=c.find(t=>t.family===e.family);n?n.swatches.push(o[t]):c.push({family:e.family,swatches:[o[t]]})}),{prop:e,label:n,value:i,grid:s,swatches:s?[]:o,families:c}},S=[[`fontSize`,`Font size`,g?.typography?.fontSize],[`lineHeight`,`Line height`,g?.typography?.lineHeight],[`letterSpacing`,`Letter spacing`,g?.typography?.letterSpacing],[`decoration`,`Decoration`,g?.typography?.decoration],[`letterCase`,`Letter case`,g?.typography?.letterCase],[`textAlign`,`Text alignment`,g?.typography?.textAlign],[`fontWeight`,`Font weight`,g?.typography?.fontWeight],[`fontStyle`,`Font style`,g?.typography?.fontStyle],[`textColor`,`Text color`,g?.color?.text],[`backgroundColor`,`Background color`,g?.color?.background],[`padding`,`Padding`,g?.spacing?.padding],[`paddingTop`,`Padding top`,g?.spacing?.paddingTop],[`paddingRight`,`Padding right`,g?.spacing?.paddingRight],[`paddingBottom`,`Padding bottom`,g?.spacing?.paddingBottom],[`paddingLeft`,`Padding left`,g?.spacing?.paddingLeft],[`margin`,`Margin`,g?.spacing?.margin],[`marginTop`,`Margin top`,g?.spacing?.marginTop],[`marginRight`,`Margin right`,g?.spacing?.marginRight],[`marginBottom`,`Margin bottom`,g?.spacing?.marginBottom],[`marginLeft`,`Margin left`,g?.spacing?.marginLeft],[`width`,`Width`,g?.dimensions?.width],[`height`,`Height`,g?.dimensions?.height],[`minHeight`,`Minimum height`,g?.dimensions?.minHeight],[`minWidth`,`Minimum width`,g?.dimensions?.minWidth],[`flexBasis`,`Flex basis`,g?.dimensions?.flexBasis],[`aspectRatio`,`Aspect ratio`,g?.dimensions?.aspectRatio],[`gap`,`Gap`,g?.layout?.gap],[`rowGap`,`Row gap`,g?.layout?.rowGap],[`columnGap`,`Column gap`,g?.layout?.columnGap],[`justifyContent`,`Justification`,g?.layout?.justifyContent],[`alignItems`,`Items alignment`,g?.layout?.alignItems],[`flexWrap`,`Wrapping`,g?.layout?.flexWrap],[`gridColumns`,`Grid columns`,g?.layout?.gridColumns],[`borderWidth`,`Border width`,g?.border?.width],[`borderColor`,`Border color`,g?.border?.color],[`borderRadius`,`Border radius`,g?.border?.radius],[`borderStyle`,`Border style`,g?.border?.style]],C=[`paddingTop`,`paddingRight`,`paddingBottom`,`paddingLeft`],w=[`marginTop`,`marginRight`,`marginBottom`,`marginLeft`];e.paddingLinkAvailable=Fe(g,`padding`)&&C.every(e=>Fe(g,e)),e.marginLinkAvailable=Fe(g,`margin`)&&w.every(e=>Fe(g,e));let ee=(n,i,a)=>{if(!a)return!0;let o=`${r}:${n}`;return o in e.styleSidesLinked||(e.styleSidesLinked[o]=!i.some(e=>!!t.getStyle(r,e))),e.styleSidesLinked[o]};e.paddingSidesLinked=ee(`padding`,C,e.paddingLinkAvailable),e.marginSidesLinked=ee(`margin`,w,e.marginLinkAvailable),e.paddingSidesLabel=e.paddingSidesLinked?`Separate sides`:`Link sides`,e.marginSidesLabel=e.marginSidesLinked?`Separate sides`:`Link sides`,e.boxPaddingShown=e.paddingLinkAvailable,e.boxMarginShown=e.marginLinkAvailable,e.spacingBoxShown=e.boxPaddingShown||e.boxMarginShown;let T=(n,i)=>{for(let a of[`Top`,`Right`,`Bottom`,`Left`]){let o=t.getStyle(r,i?n:`${n}${a}`)??``,s=`box${n===`padding`?`Padding`:`Margin`}${a}`;e[s]=o}};T(`padding`,e.paddingSidesLinked),T(`margin`,e.marginSidesLinked);let E=e.boxActiveKind===`margin`?`margin`:`padding`,te=[`Top`,`Right`,`Bottom`,`Left`].includes(e.boxActiveSide)?e.boxActiveSide:`Top`,D=E===`padding`?e.paddingSidesLinked:e.marginSidesLinked;e.boxActiveKey=`${E}-${te}`,e.boxActiveLabel=`${E===`padding`?`Padding`:`Margin`} (${D?`all sides`:te.toLowerCase()})`,e.boxActiveValue=t.getStyle(r,D?E:`${E}${te}`)??``,e.boxActiveRangeIndex=pe.findIndex(t=>t===e.boxActiveValue)+1,e.optionalStyleControls=S.filter(([t,,n])=>n&&typeof n==`object`&&n.default===!1&&!(e.paddingLinkAvailable&&C.includes(t))&&!(e.marginLinkAvailable&&w.includes(t))).map(([n,i])=>({prop:n,label:i,enabled:!!e.styleOptional[n]||!!t.getStyle(r,n)}));let O=n=>{let i=S.find(([e])=>e===n)?.[2];return!i||!Fe(g,n)?!1:typeof i==`boolean`||i.default!==!1||!!e.styleOptional[n]||!!t.getStyle(r,n)},ne=O(`fontSize`);e.styleDisabled=!t.canStyle(r);let re=ne?b(`fontSize`,`Font size`,ue(y).map(e=>({key:e.key,label:e.key}))):null;e.fontSizeOptions=re?.options??[],e.fontSizeIsSelect=re?.isSelect??!1,e.fontSizeValue=re?.value??``,e.colorRows=[{prop:`textColor`,label:`Text`,shown:O(`textColor`)},{prop:`backgroundColor`,label:`Background`,shown:O(`backgroundColor`)}].filter(e=>e.shown).map(e=>x(e.prop,e.label)),e.dimensionRows=[{prop:`padding`,label:`Padding`,shown:!e.paddingLinkAvailable&&O(`padding`)},...C.map(t=>({prop:t,label:t.replace(/([A-Z])/g,` $1`).toLowerCase().replace(/^./,e=>e.toUpperCase()),shown:!e.paddingLinkAvailable&&O(t)})),{prop:`margin`,label:`Margin`,shown:!e.marginLinkAvailable&&O(`margin`)},...w.map(t=>({prop:t,label:t.replace(/([A-Z])/g,` $1`).toLowerCase().replace(/^./,e=>e.toUpperCase()),shown:!e.marginLinkAvailable&&O(t)})),{prop:`width`,label:`Width`,shown:O(`width`)},{prop:`height`,label:`Height`,shown:O(`height`)},{prop:`minHeight`,label:`Minimum height`,shown:O(`minHeight`)},{prop:`minWidth`,label:`Minimum width`,shown:O(`minWidth`)},{prop:`flexBasis`,label:`Flex basis`,shown:O(`flexBasis`)}].filter(e=>e.shown).map(e=>b(e.prop,e.label,pe.map(e=>({key:e,label:e}))));let ie=typeof g?.dimensions?.aspectRatio==`object`&&g.dimensions.aspectRatio.values?g.dimensions.aspectRatio.values:[`auto`,`square`,`video`];O(`aspectRatio`)&&e.dimensionRows.push(b(`aspectRatio`,`Aspect ratio`,ie.map(e=>({key:e,label:e})))),e.dimensionPanelShown=e.spacingBoxShown||!!e.dimensionRows.length,e.layoutRows=[O(`gap`)?b(`gap`,`Gap`,pe.map(e=>({key:e,label:e}))):null,O(`rowGap`)?b(`rowGap`,`Row gap`,pe.map(e=>({key:e,label:e}))):null,O(`columnGap`)?b(`columnGap`,`Column gap`,pe.map(e=>({key:e,label:e}))):null,O(`justifyContent`)?b(`justifyContent`,`Justification`,B.map(({key:e,label:t})=>({key:e,label:t})),!0,!1):null,O(`alignItems`)?b(`alignItems`,`Items alignment`,Se.map(({key:e,label:t})=>({key:e,label:t})),!0,!1):null,O(`flexWrap`)?b(`flexWrap`,`Wrapping`,V.map(({key:e,label:t})=>({key:e,label:t})),!0,!1):null,O(`gridColumns`)?b(`gridColumns`,`Grid columns`,(typeof g?.layout?.gridColumns==`object`&&g.layout.gridColumns.values?g.layout.gridColumns.values:[`1`,`2`,`3`,`4`,`5`,`6`]).map(e=>({key:e,label:e}))):null].filter(e=>!!e);let ae=t.getStyle(r,`borderWidth`);e.borderWidthOptions=O(`borderWidth`)?me.map(e=>({key:e,label:e,pressed:e===ae})):[],e.borderWidthRangeIndex=e.borderWidthOptions.findIndex(e=>e.key===ae)+1,e.borderWidthRangeMax=e.borderWidthOptions.length,e.borderWidthValue=ae??``;let oe=O(`borderRadius`)?b(`borderRadius`,`Radius`,de(y).map(e=>({key:e.key,label:e.key}))):null;e.borderRadiusOptions=oe?.options??[],e.borderRadiusIsSelect=oe?.isSelect??!1,e.borderRadiusValue=oe?.value??``,e.borderRadiusRangeIndex=oe?.rangeIndex??0,e.borderRadiusRangeMax=oe?.rangeMax??0;let k=O(`borderColor`)?x(`borderColor`,`Color`):null;e.borderColorShown=!!k,e.borderColorGrid=k?.grid??!1,e.borderColorValue=k?.value??``,e.borderColorSwatches=k?.swatches??[],e.borderColorFamilies=k?.families??[];let se=t.getStyle(r,`borderStyle`);e.borderStyleOptions=O(`borderStyle`)?Ce.map(({key:e,label:t})=>({key:e,label:t,pressed:e===se})):[],e.borderShown=!!e.borderWidthOptions.length||!!e.borderRadiusOptions.length||e.borderColorShown||!!e.borderStyleOptions.length,e.typographyRows=[[`lineHeight`,`Line height`,fe(y).map(e=>({key:e.key,label:e.key})),O(`lineHeight`),!1],[`textAlign`,`Text alignment`,ye.map(({key:e,label:t})=>({key:e,label:t})),O(`textAlign`),!0],[`fontWeight`,`Font weight`,be.map(({key:e,label:t})=>({key:e,label:t})),O(`fontWeight`),!0],[`fontStyle`,`Font style`,xe.map(({key:e,label:t})=>({key:e,label:t})),O(`fontStyle`),!0],[`letterSpacing`,`Letter spacing`,L(y).map(e=>({key:e.key,label:e.key})),O(`letterSpacing`),!1],[`decoration`,`Decoration`,_e.map(e=>({key:e.key,label:e.label})),O(`decoration`),!0],[`letterCase`,`Letter case`,ve.map(e=>({key:e.key,label:e.label})),O(`letterCase`),!0]].filter(([,,,e])=>e).map(([e,t,n,,r])=>b(e,t,n,r)),e.styleFontSizeShown=ne||!!e.typographyRows.length;let ce=(t.getBlock(r)?.classes??``).split(/\s+/).filter(Boolean);e.unresolvedChips=Ke(ce).map(e=>({cls:e.cls,suffix:e.suffix,ns:e.namespaces[0],label:e.namespaces.map(t=>`--${t}-${e.suffix}`).join(`  or  `)}))}else e.blockDescription=``,e.blockSettings=[],e.blockHasStyles=!1,e.styleHasValues=!1,e.blockInspectorTab=`settings`,e.styleFontSizeShown=!1,e.fontSizeOptions=[],e.fontSizeIsSelect=!1,e.fontSizeValue=``,e.variationOptions=[],e.colorRows=[],e.dimensionRows=[],e.dimensionPanelShown=!1,e.spacingBoxShown=!1,e.boxPaddingShown=!1,e.boxMarginShown=!1,e.paddingLinkAvailable=!1,e.paddingSidesLinked=!0,e.paddingSidesLabel=`Separate sides`,e.marginLinkAvailable=!1,e.marginSidesLinked=!0,e.marginSidesLabel=`Separate sides`,e.layoutRows=[],e.borderShown=!1,e.borderWidthOptions=[],e.borderWidthValue=``,e.borderRadiusOptions=[],e.borderRadiusIsSelect=!1,e.borderRadiusValue=``,e.borderStyleOptions=[],e.borderColorShown=!1,e.borderColorGrid=!1,e.borderColorValue=``,e.borderColorSwatches=[],e.borderColorFamilies=[],e.typographyRows=[],e.optionalStyleControls=[],e.styleOptionalOpen=!1,e.unresolvedChips=[],e.blockIsPattern=!1,e.blockPattern=``,e.blockPatternRoot=``,e.blockPatternContent=[];e.emptyNote=n>1?`${n} blocks selected.`:`No block selected.`}function ee(){let n=t.selection.blocks.length,r=p(),i=r?vt(t.getModel().blocks,r):null;e.breadcrumb=n>1?`Document › ${n} blocks selected`:i?[`Document`,...i.map(e=>c(e))].join(` › `):`Document`}function T(e){let n=e.startsWith(`pattern:`)?e.slice(8):null,r=d()??i,a=r?t.getBlock(r):null;if(r&&a?.type===`paragraph`&&!h(a.fields.body).trim())n?t.replaceWithPattern(r,n):t.replaceBlock(r,e);else if(r&&a){let i=t.getModel(),a=gt(i.blocks,r),o=a&&a.list===i.blocks?a.index+1:void 0;n?t.insertPattern(n,o):t.insertBlock(e,o)}else n?t.insertPattern(n):t.insertBlock(e)}function E(t){e.inserterOpen!==t&&(t&&(te(!1),i=d(),e.query=``,e.libraryEpoch++),e.inserterOpen=t,t&&requestAnimationFrame(()=>document.getElementById(`library-search`)?.focus()))}function te(t){e.treeOpen!==t&&(t&&E(!1),e.treeOpen=t)}function D(t){t&&(i=t),e.explorerQuery=``,e.explorerGroup=e.patternGroup||`All`,e.explorerOpen=!0,document.addEventListener(`keydown`,ne,!0),requestAnimationFrame(()=>document.getElementById(`explorer-search`)?.focus())}function O(){document.removeEventListener(`keydown`,ne,!0),e.explorerOpen&&(e.explorerOpen=!1,document.getElementById(`pattern-explore`)?.focus())}function ne(e){e.key===`Escape`&&(e.stopPropagation(),O())}let re=null,ie=null,ae=null,oe=[];function k(r,i,a=``){ae=t.serialize(),e.templateLabel=r,e.templateError=``,te(!1),E(!1),oe=a.split(/\s+/).filter(Boolean),oe.length&&n.classList.add(...oe),t.setPatternsOpaque(!1),t.loadHtml(i);let o=t.getModel().blocks[0];o&&t.selectBlock(o.id)}function se(t){let n=Ot(t);!n||e.templateMode||(re=t,e.templateMode=`definition`,e.templateIsInstance=!1,k(n.label,n.content))}function ce(n){let r=t.getBlock(n),i=r?.pattern?Ot(r.pattern):void 0;!r?.children||e.templateMode||(ie=n,e.templateMode=`instance`,e.templateIsInstance=!0,k(i?.label??`Pattern`,ht({blocks:r.children}),r.classes))}function j(){if(!e.templateMode)return;let r=ie;e.templateMode=!1,e.templateError=``,re=null,ie=null,oe.length&&n.classList.remove(...oe),oe=[],t.setPatternsOpaque(!0),t.loadHtml(ae??``),ae=null,r&&t.selectBlock(r)}function M(){if(e.templateMode===`instance`){let e=ie,n=t.serialize();j(),e&&t.setBlockChildren(e,n);return}if(!re||!Ot(re))return;let n=re;try{let{kind:e}=At(n,t.serialize());if(e===`none`){j();return}}catch(t){e.templateError=t instanceof Error?t.message:String(t);return}_s.delete(n);for(let e of document.querySelectorAll(`[data-pattern-preview="${CSS.escape(n)}"]`))delete e.dataset.filled,e.textContent=``,e.style.height=``;e.libraryEpoch++,requestAnimationFrame(ys),j()}return{state:e,actions:{swallow(){},preview(){let e=t.serialize({pipeline:`data`}),n=window.open(``,`_blank`);(async()=>{let t=``;try{fs&&(t=`${ps}\n${(await fs.compile($o(e))).css}`)}catch(e){console.warn(`[preview] engine compile failed:`,e)}t+=`\n${io.css?.()??``}`;let r=`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Preview</title><style>${t}</style></head><body>${e}</body></html>`;n?n.document.write(r):window.open(URL.createObjectURL(new Blob([r],{type:`text/html`})),`_blank`)})()},toggleOutput:()=>e.outputShown=!e.outputShown,copyEditing:()=>void navigator.clipboard.writeText(t.serialize()),copyData:()=>void navigator.clipboard.writeText(t.serialize({pipeline:`data`})),setSidebarTab(t){t.tab&&(e.sidebarTab=t.tab),t.tab===`design`&&S()},setBlockInspectorTab(t){t.itab===`settings`&&(e.blockInspectorTab=`settings`),t.itab===`styles`&&e.blockHasStyles&&(e.blockInspectorTab=`styles`)},resetBlockStyles(){let e=p();e&&t.resetStyles(e)},toggleStyleOptions(){e.styleOptionalOpen=!e.styleOptionalOpen},toggleOptionalStyle(t){t.prop&&(e.styleOptional[t.prop]=!e.styleOptional[t.prop],w())},resetStylePanel(e){let n=p();n&&e.panel&&t.resetStylePanel(n,e.panel)},applySetting(e){!e.id||!e.value||(e.mode===`transform`?t.transformBlock(e.id,e.value):e.mode===`setting`&&e.setting?t.setSetting(e.id,e.setting,e.value):e.field&&t.setField(e.id,e.field,e.value))},toggleSetting(e){e.id&&e.setting&&t.setSetting(e.id,e.setting,e.pressed!==`true`)},resetSettingSection(e){e.id&&e.role&&t.resetSettings(e.id,e.role)},toggleSettingSection(t){t.section&&(e.settingSectionOpen[t.section]=e.settingSectionOpen[t.section]===!1,w())},applyFontSize(e){let n=p();!n||!e.key||t.setStyle(n,`fontSize`,t.getStyle(n,`fontSize`)===e.key?``:e.key)},applyVariation(e){let n=p();if(!n||!e.name)return;let r=t.getStyle(n,`variation`);t.setStyle(n,`variation`,e.name==="default"||e.name===r?``:e.name)},applyColor(e){let n=p();if(!n||!e.prop)return;let r=e.value&&e.value!==t.getStyle(n,e.prop)?e.value:``;t.setStyle(n,e.prop,r),e.prop===`borderColor`&&r&&!t.getStyle(n,`borderWidth`)&&t.setStyle(n,`borderWidth`,`1`)},applyStyleSelect(e,n){let r=p();!r||!e.prop||t.setStyle(r,e.prop,n.event.target.value)},designUpdateToken(e,t){let n=t.event.target.value.trim();!e.name||!n||C(A().tokens.map(t=>t.name===e.name?{name:t.name,value:n}:t))},designRemoveToken(e){e.name&&C(A().tokens.filter(t=>t.name!==e.name&&!t.name.startsWith(`${e.name}--`)))},designAddToken(e,t){let n=t.event.target.closest(`[data-add]`),[r,i]=n?[...n.querySelectorAll(`input`)]:[],a=r?.value.trim(),o=i?.value.trim();if(!e.ns||!a||!o)return;let s=`${e.ns}-${a}`;C([...A().tokens.filter(e=>e.name!==s),{name:s,value:o}]),r&&(r.value=``),i&&(i.value=``)},designSetSpacing(e,t){let n=t.event.target.value.trim();if(!n)return;let r=A().tokens.filter(e=>e.name!==`spacing`);C([{name:`spacing`,value:n},...r])},designImport(t,n){let r=n.event.target.closest(`[data-import]`)?.querySelector(`textarea`),i=r?z(r.value):null;if(!i){e.designImportError=`No @theme { --token: value; } block found.`;return}e.designImportError=``,C(i.tokens),r&&(r.value=``)},defineFromChip(t){!t.ns||!t.suffix||(e.defineName=`${t.ns}-${t.suffix}`,e.defineShown=!0,e.sidebarTab=`design`,S())},designDefine(t,n){let r=n.event.target.closest(`[data-define]`),[i,a]=r?[...r.querySelectorAll(`input`)]:[],o=i?.value.trim().replace(/^--/,``),s=a?.value.trim();!o||!s||(C([...A().tokens.filter(e=>e.name!==o),{name:o,value:s}]),e.defineShown=!1,e.defineName=``)},defineDismiss(){e.defineShown=!1,e.defineName=``},cssToClasses(t,n){let r=n.event.target.closest(`[data-css-import]`)?.querySelector(`textarea`);!fs?.classesFromCss||!r||fs.classesFromCss(r.value).then(t=>{e.cssImportResult=t.join(` `)})},applyDimension(e){let n=p();if(!n||!e.prop||!e.key)return;let r=e.key===`none`?``:e.key;t.setStyle(n,e.prop,r===t.getStyle(n,e.prop)?``:r)},applyStyleRange(n,r){let i=p();if(!i||!n.prop)return;let a=[...e.dimensionRows,...e.layoutRows,...e.typographyRows].find(e=>e.prop===n.prop);if(!a)return;let o=Number(r.event.target.value);t.setStyle(i,n.prop,o>0?a.options[o-1]?.key??``:``)},applyBorderRange(n,r){let i=p();if(!i||n.prop!==`borderWidth`&&n.prop!==`borderRadius`)return;let a=n.prop===`borderWidth`?e.borderWidthOptions:e.borderRadiusOptions,o=Number(r.event.target.value);t.setStyle(i,n.prop,o>0?a[o-1]?.key??``:``)},applyBoxSpacing(n,r){let i=p(),a=n.kind===`margin`?`margin`:n.kind===`padding`?`padding`:null,o=[`Top`,`Right`,`Bottom`,`Left`].find(e=>e===n.side);if(!i||!a||!o)return;let s=e.styleSidesLinked[`${i}:${a}`]!==!1;t.setStyle(i,s?a:`${a}${o}`,r.event.target.value.trim())},selectBoxSide(t){let n=p(),r=t.kind===`margin`?`margin`:t.kind===`padding`?`padding`:null,i=[`Top`,`Right`,`Bottom`,`Left`].find(e=>e===t.side);!n||!r||!i||(e.boxActiveKind=r,e.boxActiveSide=i,w())},applyBoxScale(n,r){let i=p(),a=e.boxActiveKind===`margin`?`margin`:`padding`,o=e.boxActiveSide;if(!i)return;let s=Number(r.event.target.value),c=s>0?pe[s-1]??``:``,l=e.styleSidesLinked[`${i}:${a}`]!==!1;t.setStyle(i,l?a:`${a}${o}`,c)},toggleSpacingSides(n){let r=p(),i=n.kind===`margin`?`margin`:n.kind===`padding`?`padding`:null;if(!r||!i)return;let a=[`Top`,`Right`,`Bottom`,`Left`].map(e=>`${i}${e}`),o=`${r}:${i}`,s=e.styleSidesLinked[o]!==!1,c={};if(s){let e=t.getStyle(r,i)??``;c[i]=``;for(let t of a)c[t]=e}else{c[i]=a.map(e=>t.getStyle(r,e)??``).find(Boolean)??``;for(let e of a)c[e]=``}e.styleSidesLinked[o]=!s,t.setStyles(r,c),w()},applyStyleInput(e,n){let r=p();!r||!e.prop||t.setStyle(r,e.prop,n.event.target.value.trim())},applyInputSetting(n,r){let i=r.event.target;if(!(!n.id||!n.setting&&!n.field))if(n.kind===`number`&&n.setting){let r=i,a=Number(r.value),o=r.min===``?null:Number(r.min),s=r.max===``?null:Number(r.max);r.value.trim()!==``&&Number.isFinite(a)&&(o===null||a>=o)&&(s===null||a<=s)?(n.key&&delete e.settingErrors[n.key],t.setSetting(n.id,n.setting,a)):(n.key&&(e.settingErrors[n.key]=o!==null&&s!==null?`Enter a value from ${o} to ${s}.`:o===null?s===null?`Enter a valid number.`:`Enter a value no greater than ${s}.`:`Enter a value of at least ${o}.`),w())}else n.setting?(n.key&&delete e.settingErrors[n.key],t.setSetting(n.id,n.setting,i.value)):n.field&&(n.key&&delete e.settingErrors[n.key],t.setField(n.id,n.field,i.value))},async uploadMedia(n,r){let i=r.event.target,a=i.files?.[0];if(i.value=``,!n.id||!n.field||!a||!us.upload)return;n.key&&(delete e.settingErrors[n.key],e.mediaBusy[n.key]=`Uploading…`,w());let o=m(n.id,n.field);try{let e=await us.upload(a);t.setField(n.id,n.field,await Oo(e,{file:a,prevAlt:o.alt}))}catch(t){console.error(`[publr-editor] media upload failed:`,t),n.key&&(e.settingErrors[n.key]=`Upload failed.`)}finally{n.key&&delete e.mediaBusy[n.key],w()}},async browseMedia(n){if(!n.id||!n.field||!us.browse)return;n.key&&(delete e.settingErrors[n.key],e.mediaBusy[n.key]=`Media library open…`,w());let r=m(n.id,n.field);try{let e=await us.browse(r.src?{...r}:void 0);e&&t.setField(n.id,n.field,await Oo(e,{prevAlt:r.alt}))}catch(t){console.error(`[publr-editor] media browse failed:`,t),n.key&&(e.settingErrors[n.key]=`Couldn't get media from the library.`)}finally{n.key&&delete e.mediaBusy[n.key],w()}},applyMediaUrl(e,n){let r=n.event.target;if(!e.id||!e.field)return;let i=m(e.id,e.field);t.setField(e.id,e.field,{src:r.value.trim(),alt:i.alt,width:``,height:``})},applyMediaAlt(e,n){let r=n.event.target;if(!e.id||!e.field)return;let i=m(e.id,e.field);t.setField(e.id,e.field,{...i,alt:r.value})},clearMedia(e){e.id&&e.field&&t.setField(e.id,e.field,{src:``,alt:``,width:``,height:``})},toggleInserter:()=>E(!e.inserterOpen),closeInserter(){E(!1),document.getElementById(`inserter-toggle`)?.focus()},setInserterTab(t){t.itab&&(e.inserterTab=t.itab)},pickBlock(e){e.blockType&&T(e.blockType)},libraryPickFirst(){let t=e.shelves[0]?.blocks[0];t&&T(t.type)},pickPatternGroup(t){t.group&&(e.patternGroup=e.patternGroup===t.group?``:t.group)},closePatternFlyout(){e.patternGroup=``,e.patternQuery=``},pickPattern(e){e.pattern&&T(`pattern:${e.pattern}`)},openPatternExplorer:()=>D(),closePatternExplorer:O,setExplorerGroup(t){t.group&&(e.explorerGroup=t.group)},explorerPick(e){e.pattern&&(O(),T(`pattern:${e.pattern}`))},sidebarEditPattern(){e.blockPatternRoot&&ce(e.blockPatternRoot)},editDefinition(e){e.pattern&&se(e.pattern)},editDefinitionFromExplorer(e){e.pattern&&(O(),se(e.pattern))},selectPatternChild(e){e.id&&t.selectBlock(e.id)},saveTemplate:M,cancelTemplate:j,toggleTree:()=>te(!e.treeOpen),closeTree(){te(!1),document.getElementById(`tree-toggle`)?.focus()},setTreeTab(t){t.ttab&&(e.treeTab=t.ttab)},treeToggle(t){t.id&&(e.treeExpanded[t.id]=!e.treeExpanded[t.id])},treeSelect(e,n){if(!e.id)return;let r=n.event;r.metaKey||r.ctrlKey?t.selectBlock(e.id,{toggle:!0,center:!0}):r.shiftKey?t.selectBlock(e.id,{range:!0,center:!0}):t.selectBlock(e.id,{center:!0})}},setup({el:a}){fo(),n=a.querySelector(`#canvas`),r=a.querySelector(`.wrap`),us.ready.then(()=>w());let o=ls??{container:a};t=ao({canvas:n,defaultBlock:o.defaultBlock??`paragraph`,groupBlock:o.groupBlock??`group`,theme:o.theme,styleBackend:o.styleBackend,policy:o.policy,placeholder:o.placeholder,debug:o.debug,onChange:()=>{e.wireEditing=t.serialize(),e.wireData=t.serialize({pipeline:`data`}),x(),w(),ee(),e.docEpoch++,o.onChange?.(t)}}),za.editor=t,za.store(`editor`,{state:{history:t.history,selection:t.selection},actions:{undo:()=>t.undo(),redo:()=>t.redo()}}),Zo(t,{container:r,media:o.media,onBrowseAll:e=>{E(!0),e&&(i=e)},onEditPattern:(e,t)=>ce(t),onBrowsePatterns:e=>D(e)});let s=[`Text`,`Media`,`Design`],c=e=>{let t=s.indexOf(e);return t===-1?s.length:t};J(()=>{e.libraryEpoch;let t=e.query.toLowerCase(),n=new Map;for(let e of rt()){if(e.internal)continue;let r=l(e);if(!u(r,t))continue;let i=e.category??`Text`;n.has(i)||n.set(i,[]),n.get(i).push(r)}e.shelves=[...n.entries()].sort(([e],[t])=>c(e)-c(t)).map(([e,t])=>({name:e,blocks:t})),e.noResults=e.shelves.length===0}),J(()=>{e.libraryEpoch;let t=[`All`,...new Set(kt().map(e=>e.category??`Uncategorized`))];e.patternGroups=t.map(t=>({name:t,selected:t===(e.patternGroup||null)})),e.explorerGroups=t.map(t=>({name:t,selected:t===e.explorerGroup}))}),J(()=>{let t=e.patternQuery.trim().toLowerCase(),n=e.patternGroup;e.patternItems=kt().filter(e=>t?e.label.toLowerCase().includes(t)||e.name.includes(t):n===`All`||(e.category??`Uncategorized`)===n).map(e=>({name:e.name,label:e.label})),e.patternFlyoutTitle=t?`Search results`:n,e.patternFlyoutOpen=e.inserterOpen&&e.inserterTab===`patterns`&&(!!t||!!n),e.patternNoResults=e.patternFlyoutOpen&&e.patternItems.length===0}),J(()=>{let t=e.explorerQuery.trim().toLowerCase(),n=e.explorerGroup;e.explorerItems=kt().filter(e=>n===`All`||(e.category??`Uncategorized`)===n).filter(e=>!t||e.label.toLowerCase().includes(t)||e.name.includes(t)).map(e=>({name:e.name,label:e.label})),e.explorerNoResults=e.explorerItems.length===0}),J(()=>{e.patternItems,e.explorerItems,e.patternFlyoutOpen,e.explorerOpen,requestAnimationFrame(ys)}),J(g),J(_),J(()=>{let n=t.selection.active??t.selection.blocks[0];if(!n)return;let r=vt(t.getModel().blocks,n);if(r)for(let t of r.slice(0,-1))e.treeExpanded[t.id]=!0}),J(w),J(ee);let f=``;J(()=>{let n=t.selection.blocks,r=(t.selection.active??(n.length?n.join(` `):``))||(p()??``);r!==f&&(f=r,e.sidebarTab=r?`block`:`document`)});let m=()=>{e.inserterOpen&&(i=d()??i)};document.addEventListener(`selectionchange`,m);let h=()=>{let e=a.querySelector(`.wrap`);e?.classList.remove(`max-w-[660px]`,`px-5`,`pt-16`,`text-[15px]`,`leading-[1.6]`),e?.classList.add(`max-w-none`,`px-0`,`pt-0`,`text-base`,`leading-normal`)};o.wide&&h(),document.head.appendChild(ds);let v=(t,n)=>{fs=t,e.engineActive=!!t,e.engineLabel=n??(t?`live (host engine)`:`none — build-time CSS only`),t&&x(),S()};return v(fs,o.engineLabel),ms.editor=t,ms.refreshCss=x,ms.syncDesignPanel=S,ms.applyTheme=C,ms.setWide=h,ms.setEngine=v,o.content!=null&&(t.loadHtml(o.content),x()),()=>document.removeEventListener(`selectionchange`,m)}}});var bs=`flex h-8 cursor-pointer items-center rounded-lg bg-primary px-3 text-[13px] font-medium text-primary-foreground shadow-xs hover:bg-primary/90 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring`,xs=`flex h-8 cursor-pointer items-center rounded-lg border border-border bg-background px-3 text-[13px] font-medium text-foreground hover:bg-muted focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring`,Ss=`flex h-9 w-9 cursor-pointer items-center justify-center rounded-xs text-neutral-900 hover:bg-neutral-100 focus-visible:shadow-[inset_0_0_0_1.5px_var(--color-accent)] focus-visible:outline-none`;function Cs(e,t,n){let r=e.querySelector(`#host-actions`);for(let e of n.actions??[]){if(!r)break;let n=document.createElement(`button`);n.type=`button`,n.dataset.hostAction=e.id,n.textContent=e.label,e.title&&(n.title=e.title),e.primary&&(n.dataset.hostPrimary=``),n.className=e.primary?bs:xs,n.addEventListener(`click`,()=>e.onClick(t)),r.appendChild(n)}let i=e.querySelector(`#host-panel-toggles`),a=e.querySelector(`#host-panels`),o=new Map,s=new Map,c=e.querySelector(`#sidebar`),l=(e,t)=>{let n=s.get(e);if(!n)return;let r=t??n.hidden;if(r)for(let[t,n]of s)t!==e&&(n.hidden=!0,o.get(t)?.setAttribute(`aria-expanded`,`false`));if(n.hidden=!r,o.get(e)?.setAttribute(`aria-expanded`,String(r)),c){let e=[...s.values()].some(e=>!e.hidden);c.style.display=e?`none`:``}};for(let e of n.panels??[]){if(!i||!a)break;let n=document.createElement(`aside`);n.dataset.hostPanel=e.id,n.className=`pbe-ui flex w-80 shrink-0 flex-col overflow-hidden border-l border-border bg-background max-sm:hidden`,n.hidden=!e.open;let r=document.createElement(`div`);r.className=`flex h-11 shrink-0 items-center justify-between border-b border-border px-4 text-sm font-semibold`;let c=document.createElement(`span`);c.textContent=e.title;let u=document.createElement(`button`);u.type=`button`,u.setAttribute(`aria-label`,`Close ${e.title}`),u.className=`flex h-7 w-7 cursor-pointer items-center justify-center rounded-xs text-neutral-500 hover:bg-neutral-100 hover:text-neutral-900`,u.textContent=`×`,u.addEventListener(`click`,()=>l(e.id,!1)),r.append(c,u);let d=document.createElement(`div`);d.className=`min-h-0 flex-1 overflow-y-auto`,n.append(r,d),a.appendChild(n),s.set(e.id,n);let f=document.createElement(`button`);if(f.type=`button`,f.title=e.title,f.setAttribute(`aria-label`,`Toggle ${e.title}`),f.setAttribute(`aria-expanded`,String(!!e.open)),f.className=Ss,e.icon)f.innerHTML=e.icon;else{let t=document.createElement(`span`);t.className=`text-[13px] font-semibold`,t.textContent=(e.title[0]??`?`).toUpperCase(),f.appendChild(t)}f.addEventListener(`click`,()=>l(e.id)),i.appendChild(f),o.set(e.id,f),e.mount(d,t),e.open&&l(e.id,!0)}return l}async function ws(e){await hs,ls=e,ps=e.baseCss??``,fs=e.cssEngine??null,us=To(e.media,{register:!0});let t=e.container;t.innerHTML=Qo;let n=t.querySelector(`#editor-shell`),r=e=>n?.classList.toggle(`dark`,e!==`light`);r(e.appearance??`dark`),Ra(t);let i=ms.editor;if(!i)throw Error(`[publr-editor] createEditorShell: shell failed to boot (chrome island did not initialize)`);return{editor:i,container:t,setCssEngine:(e,t)=>ms.setEngine?.(e,t),refreshCss:()=>ms.refreshCss?.(),syncDesignPanel:()=>ms.syncDesignPanel?.(),applyTheme:e=>ms.applyTheme?.(e),setWide:()=>ms.setWide?.(),setAppearance:r,openPanel:Cs(t,i,e),destroy:()=>{Pa(t),t.innerHTML=``}}}return typeof window<`u`&&window.Publr&&(window.Publr.Editor={RAW_TYPE:t,escHtml:f,escAttr:p,registerBlock:tt,unregisterBlock:nt,getBlockType:q,blockTypes:rt,registerCoreBlocks:Wr,registerCorePatterns:Hr,registerPattern:Et,unregisterPattern:Dt,getPattern:Ot,patternTypes:kt,isPatternContentBlock:Lt,patternContentBlocks:Rt,upcast:ut,downcast:ht,blockToElement:dt,createEditor:ao,attachInlineChrome:Zo,createEditorShell:ws}),e.ALIGN_ITEMS=Se,e.BORDER_STYLES=Ce,e.BORDER_WIDTH_STEPS=me,e.CHILDREN_ATTR=s,e.CORE_PATTERNS=Vr,e.DECORATIONS=_e,e.DEFAULT_BLOCK_POLICY=Va,e.DEFAULT_THEME=k,e.FLEX_WRAPS=V,e.FONT_STYLES=xe,e.FONT_WEIGHTS=be,e.ICONS=so,e.JUSTIFY_CONTENT=B,e.LETTER_CASES=ve,e.MEDIA_PREFIX=mo,e.PATTERN_ATTR=c,e.PATTERN_ROOT_TYPE=bt,e.RAW_TYPE=t,e.SPACING_STEPS=pe,e.STYLE_PROPS=je,e.TEXT_ALIGNMENTS=ye,e.activeTheme=A,e.attachInlineChrome=Zo,e.blockSupportsStyle=Fe,e.blockToElement=dt,e.blockTypes=rt,e.bumpPatternVersion=Nt,e.classesBackend=Qa,e.cloneValue=n,e.collectClasses=$o,e.colors=I,e.comparePatternVersions=Mt,e.createEditor=ao,e.createEditorShell=ws,e.deleteMedia=Co,e.diffPatternContent=Ft,e.downcast=ht,e.escAttr=p,e.escHtml=f,e.flattenBlocks=_t,e.fontSizes=ue,e.getBlockType=q,e.getMedia=xo,e.getPattern=Ot,e.getPatternContent=jt,e.hasToken=N,e.httpCssEngine=ns,e.iconRef=po,e.iconSvg=X,e.inlineBackend=io,e.isPatternContentBlock=Lt,e.leadings=fe,e.listMedia=So,e.locateBlock=gt,e.mediaStoreSupported=_o,e.mountIconSprite=fo,e.patchStyleClasses=We,e.pathToBlock=vt,e.patternContentBlocks=Rt,e.patternTypes=kt,e.probeCssEngine=rs,e.publishPattern=At,e.putMedia=bo,e.radii=de,e.readStyleClass=Ue,e.registerBlock=tt,e.registerCoreBlocks=Wr,e.registerCorePatterns=Hr,e.registerMediaWorker=wo,e.registerPattern=Et,e.resolveBlockPolicy=qa,e.resolveRootPolicy=Ka,e.runtimeThemeCss=ts,e.setActiveTheme=ce,e.spacingBase=R,e.str=r,e.styleClasses=Pe,e.themeFromCssText=z,e.themeFromTokens=P,e.themeToCssText=he,e.tokenValue=le,e.trackings=L,e.unregisterBlock=nt,e.unregisterPattern=Dt,e.unresolvedUtilities=Ke,e.upcast=ut,e.variationClasses=Ne,e})({});