
- install powershell (its cross-platform, so yes, you can run this if youre not on windows)
- install mkcert 
    - make sure you run `mkcert install` after install mkcert cli so that it can make the changes that it needs to, to your computers certificate settings
- have podman or docker desktop running



then run 


```
pwsh .\create-kind-cluster.ps1
```