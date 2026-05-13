# Подводные камни реализации

Этот документ фиксирует неочевидные места схемы `wg1 -> RU VPS -> wg0/FI или WAN`.
Он полезен при переносе на новую машину, отладке "handshake есть, сайты не
открываются" и при изменении правил маршрутизации.

## Общая модель

На RU VPS есть три важные стороны:

- `wg1` - входящий WireGuard для пользовательских клиентов.
- `wg0` - исходящий WireGuard-туннель до FI.
- `WAN_IF` - внешний интерфейс RU VPS, например `enp3s0` или `dev0`.

Трафик клиентов маркируется в `nftables`, а затем уходит через policy routing:

- `RU_MARK` -> таблица `split_ru_direct` -> внешний интерфейс RU VPS.
- `WG_MARK` -> таблица `split_wg_out` -> `wg0`.
- без явного совпадения трафик получает `WG_MARK`, то есть по умолчанию уходит
  через FI.

## WireGuard

`wg0` должен быть настроен с `Table = off`. Это критично: иначе `wg-quick`
может добавить маршрут `0.0.0.0/0` в main table, и тогда сам сервер начнет
уводить обычный трафик, включая SSH, через FI-туннель.

`AllowedIPs = 0.0.0.0/0` у FI peer в `wg0.conf` допустим именно потому, что
`Table = off`. Маршрут по умолчанию для клиентского трафика добавляет не
`wg-quick`, а `apply.sh` в отдельную таблицу `split_wg_out`.

`ensure-wireguard-configs.sh` только создает отсутствующие файлы
`/etc/wireguard/wg0.conf` и `/etc/wireguard/wg1.conf`. Он не поднимает
интерфейсы. На новой машине после генерации все равно нужно запустить:

```bash
sudo systemctl enable --now wg-quick@wg0.service wg-quick@wg1.service
```

`wg1.conf`, созданный автоматически, содержит только `[Interface]`. Клиентов
нужно добавлять отдельно через `add-wg1-client.sh`.

При добавлении peer в уже поднятый `wg1` через `wg set` важен маршрут до
клиента, например `10.40.0.3/32 dev wg1`. Поэтому `add-wg1-client.sh` делает:

```bash
ip -4 route replace "$client_ip" dev "$wg_if"
```

Без этого может быть ситуация: handshake есть, bytes идут, но ответы клиенту
пытаются уйти через внешний интерфейс.

## FI-сервер

FI должен знать не только адрес RU в transit-сети, но и клиентскую подсеть,
которая приходит за RU. Например:

```ini
AllowedIPs = 10.30.0.3/32, 10.40.0.0/24
```

Если забыть клиентскую подсеть, FI сможет держать handshake с RU, но обратный
маршрут для клиентов будет отсутствовать или уйдет не туда.

На FI нужен NAT в сторону внешнего интерфейса, обычно:

```bash
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
```

Имя интерфейса (`eth0`) на конкретной FI-машине нужно проверять.

## DNS и классификация доменов

Домены классифицируются не сами по себе, а через IP-адреса, полученные в ответе
DNS. Пока клиент не резолвил домен через dnsmasq на VPS, в set может не быть IP
для этого домена.

Клиенты должны использовать DNS-адрес VPS на `wg1`, например `10.40.0.1`.
Проект дополнительно редиректит UDP/TCP 53 от клиентов на локальный dnsmasq,
но DoH/DoT это не покрывает.

Провайдерский DNS на RU-интерфейсе может отдавать отравленные ответы для
заблокированных ресурсов. Поэтому `DNS_UPSTREAMS` принудительно маршрутизируются
через `wg0`. Это важная часть дизайна, а не косметика.

DNS-sets живут ограниченное время. В nft-режиме set `ru_domain_v4` имеет
`timeout 6h`; в ipset fallback используется timeout `21600`. Из-за этого
решение по домену может исчезнуть, пока домен не будет зарезолвен снова.

CDN и shared hosting могут давать один IP для разных доменов. Если IP попал в
RU/force set, через этот путь может уйти не только один ожидаемый домен, а весь
трафик к этому IP до истечения timeout.

## dnsmasq: nftset и ipset

На Ubuntu 22.04 пакетный `dnsmasq` часто собран без `HAVE_NFTSET`. Симптом:

```text
dnsmasq: recompile with HAVE_NFTSET defined to enable nftset directives
```

Для этого есть `DNS_SET_BACKEND="auto"`: скрипт выбирает `ipset`, если видит
`no-nftset` в `dnsmasq --version`.

В ipset-режиме dnsmasq заполняет ipset, а маркировка делается через iptables
mangle. В nft-режиме dnsmasq заполняет nft set напрямую. Это два разных пути,
поэтому при диагностике нужно смотреть выбранный backend:

```bash
cat /etc/splitvpn/generated/dns-set-backend
```

## Приоритеты force-правил

Приоритет намеренно такой:

```text
force-fi.txt > force-ru.txt > .ru DNS classification > RU GeoIP > default FI
```

Это значит, что `force-fi.txt` должен выигрывать даже у GeoIP и `.ru`.

Для доменов force-правила начинают работать после DNS-резолва через VPS. Для
IP/CIDR они начинают работать сразу после:

```bash
sudo /opt/splitvpn/scripts/apply.sh
```

Формат `*.example.com` нормализуется в `example.com`. Для dnsmasq это означает
совпадение домена и поддоменов.

## nftables и iptables вместе

Проект всегда грузит nftables-таблицы `inet splitvpn`, `ip splitvpn_nat` и
`ip splitvpn_dns`. В ipset fallback дополнительно используются iptables mangle
rules для DNS-derived sets.

Это нормально, но при ручной отладке легко смотреть только `nft list ruleset` и
не заметить iptables-маркировку. Для ipset backend проверяйте оба слоя:

```bash
sudo nft list ruleset
sudo iptables -t mangle -S
sudo ipset list
```

`apply.sh` удаляет и пересоздает только свои nft-таблицы. Чужие firewall-правила
не очищаются, но могут влиять на forward/NAT раньше или позже в hook chain.

## Policy routing

`apply.sh` добавляет таблицы в `/etc/iproute2/rt_tables` и правила `ip rule`
по fwmark. Если кто-то вручную добавит правила с более высоким приоритетом,
трафик может уйти не по ожидаемому пути.

Базовая диагностика:

```bash
ip -4 rule show
ip -4 route show table split_ru_direct
ip -4 route show table split_wg_out
```

`WAN_GATEWAY` автоопределяется из default route на `WAN_IF`. Если default route
на сервере нестандартный или отсутствует, его нужно явно задать в env.

Для `wg0` обычно достаточно default route `dev wg0` в таблице `split_wg_out`.
`WG_GATEWAY` нужен только если конкретная WireGuard-схема требует next-hop.

## systemd и порядок старта

`wg1` должен стартовать после `wg0`, потому что основной маршрут клиентов по
умолчанию ведет в FI. Для этого есть drop-in:

```text
wg-quick@wg1.service.d/10-after-wg0.conf
```

`splitvpn.service` должен стартовать после обоих WireGuard-интерфейсов. Если
запустить `apply.sh`, пока `wg0` или `wg1` еще не подняты, будет ошибка
`Interface not found`.

GeoIP-обновление живет отдельно в `splitvpn-geoip.timer`. Если таймер выключен,
GeoIP-set со временем не обновится, но ручные force-правила продолжат работать.

## IPv4-only ограничение

Текущая реализация маршрутизирует только IPv4. Если клиенту отдать IPv6 или
оставить IPv6 активным поверх другого канала, часть сайтов может обходить эту
логику полностью.

Практичный вариант: не указывать IPv6 в клиентских WireGuard-конфигах и при
необходимости отключить IPv6 на клиенте для этого VPN-профиля.

## MTU

MTU `1420` обычно подходит, но не является универсальным. Если handshake есть,
DNS работает, маленькие ответы проходят, а сайты зависают на загрузке, стоит
проверить MTU/MSS.

Быстрая проверка с клиента:

```bash
ping -f -l 1372 1.1.1.1
```

Для Windows синтаксис отличается от Linux. Значение нужно подбирать с учетом
заголовков и реального пути до FI.

## Проверка egress

`check-domain-egress.sh` показывает ожидаемый путь по текущим правилам и
resolved IP. Это не полноценный браузерный e2e-тест, но хороший первый тест:

```bash
sudo /opt/splitvpn/scripts/check-domain-egress.sh vk.com
sudo /opt/splitvpn/scripts/check-domain-egress.sh example.com
```

Для клиента Windows есть helper:

```powershell
.\check-domain-egress.ps1 vk.com
```

При расхождении между checker и браузером сначала проверьте, каким DNS реально
пользуется клиент, нет ли DoH в браузере, и не закэширован ли старый DNS-ответ.

## Секреты и права

`splitvpn.env` может содержать `WG0_PRIVATE_KEY`, а WireGuard-конфиги точно
содержат private keys. Эти файлы должны оставаться с правами `600`.

Не вставляйте реальные приватные ключи в README, issue, чат или публичный git.
Для отладки достаточно public key, endpoint, AllowedIPs и masked config.

## Типичный порядок на новой машине

```bash
sudo bash scripts/install-packages-ubuntu.sh
sudo bash scripts/install.sh
sudo nano /etc/splitvpn/splitvpn.env
sudo /opt/splitvpn/scripts/ensure-wireguard-configs.sh
sudo systemctl enable --now wg-quick@wg0.service wg-quick@wg1.service
sudo /opt/splitvpn/scripts/apply.sh
sudo /opt/splitvpn/scripts/update-ru-geoip.sh
sudo systemctl enable --now splitvpn.service splitvpn-geoip.timer
```

После генерации нового `wg0` не забудьте добавить public key RU на FI-сервер.
После генерации нового `wg1` старые клиентские конфиги, завязанные на прежний
server public key, работать не будут.
