# usx-campus-auth

绍兴大学校园网自动认证脚本：路由器自己保持门户登录，宿舍里所有设备共享一个名额。
掉线后最迟 5 分钟内自动补上一次登录，不需要人管。

**不是 LuCI 插件**，没有网页界面 —— 两个文件放进 `/etc/`、挂一条 cron 就完事。

---

## 三步装好

### 1. 下载这两个文件

- [`campus_auth.sh`](campus_auth.sh) —— 主脚本
- [`presets/usx-drcom.conf.example`](presets/usx-drcom.conf.example) —— 本校配置模板

先在能上网的设备上存好（路由器本身此刻还没网，没法自己下载）。

### 2. 传进路由器

**【电脑】** PowerShell（把路径换成你下载的位置）：

```
scp campus_auth.sh root@192.168.10.1:/etc/campus_auth.sh
scp presets/usx-drcom.conf.example root@192.168.10.1:/etc/campus_auth.conf
```

**【终端】SSH 进路由器后：**

```sh
apk add curl ca-certificates
chmod 700 /etc/campus_auth.sh
chmod 600 /etc/campus_auth.conf
```

> 老版本 OpenWrt 把 `apk` 换成 `opkg update && opkg install curl ca-certificates`。

### 3. 填账号密码，跑起来

```sh
vi /etc/campus_auth.conf
```

**只改这两行**，别的一个字都别动：

```sh
USER_ACCOUNT="你的学号@telecom"     # @telecom=电信，@cmcc=移动，跟你登录页选的一致
USER_PASSWORD="你的门户密码"
```

然后：

```sh
/etc/campus_auth.sh --show-config     # 先看请求拼对了没，不发出去
/etc/campus_auth.sh -v                # 真跑一次
```

`响应:` 里出现 `已经成功登录` 或 `successlogin` 就是成了。再验一下网：

```sh
curl -s -o /dev/null -w '%{http_code}\n' -m 8 https://www.baidu.com
```

出 `200` = 通。最后交给定时器：

```sh
echo '0,5,10,15,20,25,30,35,40,45,50,55 * * * * /etc/campus_auth.sh >/dev/null 2>&1' >> /etc/crontabs/root
/etc/init.d/cron restart
```

装完就该干什么干什么去，以后它自己管。想看看跑没跑：`logread | grep campus_auth`
—— **没输出是好事**，说明一直在线，只有掉线重连那一刻才写日志。

---

## 不灵的时候

| 现象 | 怎么办 |
|---|---|
| `ERROR: 找不到 curl` | 上面第 2 步的 `apk add` 没执行 |
| `取不到校园网内网 IP` | WAN 没拿到 `172.19.x.x`，检查网线插的是不是 WAN 口 |
| 日志说失败，可 https curl 出 200 | 只是日志措辞，功能正常，不用管 |
| 装完能上，过一阵就断、且反复 | 学校那边有对抗手段，脚本解决不了 |

刷机/升级固件会清掉这些文件，所以顺手加进保留列表：

```sh
for f in /etc/campus_auth.sh /etc/campus_auth.conf /etc/crontabs/root; do echo $f >> /etc/sysupgrade.conf; done
```

---

## 别的学校想用

脚本本体和学校无关，要改的都在配置文件里。照着
[`campus_auth.conf.example`](campus_auth.conf.example) 的注释，把浏览器 F12 抓到的那条登录请求
拆成 `SERVER` / `PORT` / `AUTH_PATH` / `AUTH_QUERY` 四段填进去即可；
账号里的 `%2C0%2C` 前缀和 `@telecom` 后缀是本校专属，**别照抄**。

---

## 安全

配置文件里是你的明文密码：保持 `600`，别提交到 Git，别截图发群。
脚本自己打印日志时已经把密码位置换成 `****`。

## 许可与声明

MIT，见 [LICENSE](LICENSE)。

本项目**仅为技术分享与学习**，其余用途后果自负。
