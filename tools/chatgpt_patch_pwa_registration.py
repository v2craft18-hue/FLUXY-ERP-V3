from pathlib import Path

p = Path('index.html')
s = p.read_text(encoding='utf-8')
old = "navigator.serviceWorker.register('./sw.js',{scope:'./'})"
new = "navigator.serviceWorker.register('./sw.js',{scope:'./',updateViaCache:'none'})"
count = s.count(old)
if count != 1:
    raise SystemExit(f'expected exactly one registration marker, found {count}')
p.write_text(s.replace(old, new, 1), encoding='utf-8')
