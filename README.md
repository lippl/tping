# tping
Simple "timestamp-ping" tool, pinging continuously in background, only showing status-change (up/down) of destination host.

Available for **Linux/macOS** (`tping.sh`) and **Windows** (`tping.ps1`).

## Motivation
As a network engineer, i needed a simple tool, to monitor an availability of a target IP-address. When using "ping xyz", you get a new line entry, every ping-interval, showing the actual RTT

    schwupp@linux:~$ ping HOST1
    PING HOST1(host1.domain.name (192.168.0.1)) 56 data bytes
    64 bytes from host1.domain.name (192.168.0.1): icmp_seq=1 ttl=64 time=0.047 ms
    64 bytes from host1.domain.name (192.168.0.1): icmp_seq=2 ttl=64 time=0.035 ms
    64 bytes from host1.domain.name (192.168.0.1): icmp_seq=3 ttl=64 time=0.042 ms
    64 bytes from host1.domain.name (192.168.0.1): icmp_seq=4 ttl=64 time=0.047 ms

In most cases, you only need to know, if the target host is reachable or not, and when a state change between up and down has happened. For this usecase, the quite bloating every-second-newline-characteristic of the original ping-tool is not very useful, so i ended up in creating a simple wrapper for it, using bash.

## Example
If you use tping script, you only get one line per status-change. You have to rely on the script, that it is pinging in the background for you. This is the main difference when using it, compared to original ping (which notifies you every ping-intervall, that is it still pinging, but you only get an indirect notice, if host is down). 

    schwupp@linux:~$ tping.sh HOST1
    2022-03-23 14:40:30 | host 192.168.0.1 (host1.domain.name) is ok | RTT 2.13ms
    2022-03-23 14:41:00 | host 192.168.0.1 (host1.domain.name) is down [ok for 30 sec]
    2022-03-23 14:41:21 | host 192.168.0.1 (host1.domain.name) is ok [down for 21 sec] | RTT 1.42ms
    --- host1.domain.name (192.168.0.1) tping statistics ---
    flapped 0 times, was up for 51 sec and down for 0 sec
    51 packets transmitted, 30 packets received, 61% packet loss
    round-trip min/avg/max = 0.616/1.861/5.02 ms


- ~~What you lose, is the continous reading of the RTT (you only get the first one)~~ integrated since tping 6.1
- What you win is a clear, timestamped view when and how long a target host went off or online

## Installation (Linux/macOS)
- download latest release
- copy tping.sh to your machine
- make script executable

        schwupp@linux:~$ chmod +x tping.sh

- take a look at the parameters

        schwupp@linux:~$ tping.sh -h

- ping your first target with IP or Hostname

        schwupp@linux:~$ tping.sh 8.8.8.8

## Windows (PowerShell)

The PowerShell version (`tping.ps1`) provides the same features as the bash script on Windows.

### Installation
- Download the latest release or clone the repository
- Copy `tping.ps1` to your Windows machine
- Run with PowerShell 5.1 or later
- If scripts are blocked, run: `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`

### Usage
```powershell
.\tping.ps1 8.8.8.8
.\tping.ps1 -IPv4 google.com
```

### Example output
```
2026-02-16 14:43:20 | host 127.0.0.1 (127.0.0.1) is ok | RTT <1ms
2026-02-16 14:43:25 | host 127.0.0.1 (127.0.0.1) is down [ok for 5 sec]
--- 127.0.0.1 (127.0.0.1) tping statistics ---
flapped 1 times, was up for 5 sec and down for 0 sec
10 packets transmitted, 5 packets received, 50% packet loss
round-trip min/avg/max = 0.5/0.5/1 ms
```

Press **Ctrl+C** to stop and display statistics.
        
## Parameters

| Parameter | Linux/macOS | Windows | Description |
|-----------|--------------|---------|-------------|
| Target | positional | `-Target` (positional) | Target IP or hostname |
| Deadtime | `-W <sec>` | `-Deadtime` / `-W` | Ping timeout in seconds (default: 1) |
| Interval | `-i <sec>` | `-Interval` / `-i` | Seconds between pings (default: 1) |
| Fuzzy | `-f <#>` | `-Fuzzy` / `-f` | Failed pings before marking down; 0 disables (default: 0). Target goes "down" after #+1 failed pings. Useful on unreliable networks (e.g. cellular). |
| Static mode | `-s` | `-Static` / `-s` | Legacy mode without live RTT updates when up. Output line stays frozen until state change. |
| IPv4 only | `-4` | `-IPv4` | IPv4-only DNS lookup (default: IPv6 with fallback to IPv4) |
| Debug | `-d` | `-DebugMode` / `-d` | Verbose debug output |
| Version | `-v` | `-Version` / `-v` | Show version |
| Help | `-h` | `-Help` / `-h` | Show usage |

## HTTP probing

The repository also includes continuous HTTP(S) probes:

- `httping.sh` for Linux/macOS and other Bash environments
- `httping.ps1` for Windows PowerShell 5.1 or later

Both scripts repeatedly request a URL and report whether it is reachable with
HTTP status `200`. The expected response text can be checked with `-t`.
HTTPS is used by default; pass `-u` to use unencrypted HTTP instead. The
current `ok`, `missing`, or `down` status is updated in place rather than
printing a new line on every probe. A new line is printed when the status
changes.
Response times are displayed as whole milliseconds, for example `254ms`.
The final statistics include separate minimum, average, and maximum response
times for `ok` and `missing` checks. Failed/down checks do not track or display
response times.

### HTTP probing examples

```bash
./httping.sh https://example.com
./httping.sh -t "Welcome" https://example.com
./httping.sh -u -P 8080 -t "FindMe" example.com
```

```powershell
.\httping.ps1 https://example.com
.\httping.ps1 -t "Welcome" https://example.com
.\httping.ps1 -u -P 8080 -t "FindMe" example.com
```

The probes have three runtime states:

- **ok** (green): the request returned HTTP `200` and the expected text was
  found, or no text check was requested.
- **missing** (orange): the request returned HTTP `200`, but the expected text
  was not found.
- **down** (red): the request failed or returned a non-`200` status.

The `missing` state includes `response misses 'text'`; a successful text check
includes `response contains 'text'`.

### HTTP probe parameters

| Parameter | Description |
|-----------|-------------|
| URL | Target URL or hostname. HTTPS is used by default for hostnames. |
| `-u` | Use HTTP instead of HTTPS. |
| `-P <port>` | Override the destination port; accepts a number, `http`, or `https`. |
| `-t <text>` | Require the specified text in the response body. |
| `-W <sec>` | HTTP timeout in seconds (default: 5). |
| `-i <sec>` | Seconds between checks (default: 5). |
| `-f <#>` | Failed checks before marking down; `0` disables fuzzy detection. |
| `-d` | Enable debug output. |
| `-v` | Show version. |
| `-h` | Show usage. |
