# usx-campus-auth

**OpenWrt / ImmortalWrt 路由器上的校园网门户自动认证脚本**（绍兴大学 USX · Dr.COM eportal 已配好，开箱可用）。

一句话：让**路由器**自己保持校园网门户登录，宿舍里所有设备共享一个名额；掉线后最迟 5 分钟自动补一次登录，不需要人管。

> **不是电脑或手机上的软件，也不是 LuCI 插件**（没有网页界面）。它只有两个文件，
> 放进路由器的 `/etc/`，挂一条 cron 就完事。

---

## 设备与环境要求

**先对照这一节，不满足就别往下装。**

| 项目 | 要求 | 怎么确认 |
|---|---|---|
| 路由器固件 | **已刷 OpenWrt / ImmortalWrt**（或基于 OpenWrt 的第三方固件）。作者这台：ImmortalWrt 25.12.2 + CMCC RAX3000Me（eMMC 版） | SSH 进去看开机横幅；**原厂固件（小米/移动/华为自带的那套）跑不了** |
| 包管理器 | `apk`（OpenWrt 24.10+ / ImmortalWrt 25.x）或 `opkg`（旧版） | SSH 进去敲 `apk --version`，报 `not found` 就改敲 `opkg --version`，有一个能出版本号就行 |
| 必装的两个包 | `curl`、`ca-certificates` | `apk add curl ca-certificates` 能装上 |
| 脚本自身依赖 | 只要 `/bin/sh` + busybox 自带的 `ip awk sed grep cut head date sleep logger`，外装一个 `curl` | **不需要 bash、不需要 python**，所以不挑型号 |
| 网络拓扑 | 宿舍那根校园网线插路由器 **WAN 口**，且 WAN 能从门户 DHCP 拿到 `172.19.x.x` | 路由器上看 wan 接口有没有 172.19 地址 |
| 门户账号 | 你自己的学号 + 门户密码。Dr.COM 把运营商编码在账号后缀：`@telecom`=电信、`@cmcc`=移动 | 浏览器能手动登录成功即可 |
| 操作端电脑 | 一台能 SSH / scp 进路由器的电脑（Windows 10+ 自带 OpenSSH，macOS、Linux 同理） | PowerShell 里 `ssh root@路由器地址` 能进去 |
| 名额 | 学校限 2 台设备；路由器 NAT 后全部下游合计算 1 台 | 自助页能看到那台设备 |

**这几种情况用不了，别试：**

- 路由器是**原厂固件**、或只能用网页后台设置（没刷过 OpenWrt）
- 学校门户靠 **Cookie 会话 / JS 算签名**（老式 `0.htm`+`DDDDD`、锐捷 `InterFace.do` 加密串等）—— 本脚本只会原样重放一条静态请求，不会算签名
- 想在 **Windows 电脑上**自动登录共享给别的设备 —— 那不是这个仓库的东西（这里只让路由器自己登录）
- 光猫直连、或校园网本身是 PPPoE 拨号（那是另一套认证，参数不一样）

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

> `192.168.10.1` 换成**你自己路由器的管理地址**（OpenWrt 默认多为 `192.168.1.1`）。
> 不知道就电脑上按 `Win` → 输入 `cmd` 回车 → `ipconfig` → 看"默认网关"那一行。
> 后面所有出现 `192.168.10.1` 的地方同理。

**【终端】SSH 进路由器**（电脑上按 `Win` → 输入 `powershell` 回车，然后）：

```
ssh root@192.168.10.1
```

第一次会问 `Are you sure you want to continue connecting` → 输 `yes` 回车；
再问密码就**直接回车**（默认 root 无密码），或输你设过的 root 密码。
看到提示符变成 `root@OpenWrt:~#` 就说明已经在路由器里了，下面这些命令都粘到这个窗口：

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
