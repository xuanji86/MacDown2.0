---
title: Syntax showcase
tags: [markdown, "math"]
draft: false
---

[TOC]

# Extensions

## Inline

==highlighted==, H~2~O, E = mc^2^, _underlined_, *emphasis*, **strong**, ~~gone~~ and a footnote[^note].

Smart "quotes" -- dashes... <https://example.com> and www.example.org.

- [x] done
- [X] done in capitals
- [ ] open
  - [x] nested

| left | right |
|:-----|------:|
| a    | b     |

[^note]: The footnote text, with `code`.

## Alerts and emoji

> [!NOTE]
> A note with *inline* markup.

> [!TIP]
> - a list
> - inside a tip

> [!IMPORTANT]
> Read this.

> [!WARNING]
> Careful.

> [!CAUTION]
> Dangerous.

> An ordinary quote, and `:smile:` in code stays as written.

Short codes: :smile: :+1: :tada: :not_an_emoji:

## Math

Inline $a_b * c_d$ and \(x^2\) next to _real_ emphasis; the price is $5 and $10.

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

\[
e^{i\pi} + 1 = 0
\]

## Code

```js
/* a block
   comment */
const answer = 42; // trailing
```

```python
def f(x):
    return x ** 2
```

```unknown-lang
<not & highlighted>
```

    indented code
