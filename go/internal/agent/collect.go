package agent

import (
	"context"
	"fmt"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/disk"
	"github.com/shirou/gopsutil/v4/host"
	"github.com/shirou/gopsutil/v4/load"
	"github.com/shirou/gopsutil/v4/mem"
	gnet "github.com/shirou/gopsutil/v4/net"
	"github.com/shirou/gopsutil/v4/process"

	"github.com/harsundeepwathan/az400/go/pkg/telemetry"
)

// pseudoFS are filesystem types that never represent capacity worth alerting on.
var pseudoFS = map[string]bool{
	"proc": true, "sysfs": true, "devtmpfs": true, "devpts": true, "tmpfs": true, "cgroup": true, "cgroup2": true,
	"overlay": true, "squashfs": true, "securityfs": true, "pstore": true, "debugfs": true, "tracefs": true,
	"configfs": true, "fusectl": true, "mqueue": true, "hugetlbfs": true, "autofs": true, "bpf": true, "nsfs": true,
	"ramfs": true, "binfmt_misc": true, "rpc_pipefs": true, "efivarfs": true, "fuse.lxcfs": true, "nfsd": true,
	"selinuxfs": true, "iso9660": true,
}

// Collector gathers host metrics. Rates are computed from counter deltas between calls.
type Collector struct {
	ExcludeMounts []string

	prevCPU   []cpu.TimesStat
	prevTotal *cpu.TimesStat
	prevDisk  map[string]disk.IOCountersStat
	prevNet   *gnet.IOCountersStat
	prevAt    time.Time
	self      *process.Process
}

// NewCollector creates a collector.
func NewCollector(exclude []string) *Collector {
	p, _ := process.NewProcess(int32(os.Getpid()))
	return &Collector{ExcludeMounts: exclude, self: p}
}

// HostInfo returns host identity.
func HostInfo(ctx context.Context) telemetry.HostInfo {
	h := telemetry.HostInfo{OSType: runtime.GOOS, Arch: runtime.GOARCH, CPUCount: runtime.NumCPU(), MachineID: machineID()}
	if info, err := host.InfoWithContext(ctx); err == nil {
		h.Hostname = info.Hostname
		h.OSName = strings.TrimSpace(info.Platform)
		h.OSVersion = info.PlatformVersion
		h.KernelVersion = info.KernelVersion
		h.BootTime = time.Unix(int64(info.BootTime), 0).UTC()
		if h.MachineID == "" {
			h.MachineID = info.HostID
		}
	}
	if h.Hostname == "" {
		h.Hostname, _ = os.Hostname()
	}
	if vm, err := mem.VirtualMemoryWithContext(ctx); err == nil {
		h.MemoryBytes = vm.Total
	}
	return h
}

func busy(t cpu.TimesStat) (busy, total float64) {
	idle := t.Idle + t.Iowait
	total = t.User + t.System + t.Idle + t.Nice + t.Iowait + t.Irq + t.Softirq + t.Steal
	return total - idle, total
}

func pct(prev, cur cpu.TimesStat) (float64, bool) {
	b0, t0 := busy(prev)
	b1, t1 := busy(cur)
	if t1 <= t0 {
		return 0, false
	}
	v := (b1 - b0) / (t1 - t0) * 100
	if v < 0 {
		v = 0
	}
	if v > 100 {
		v = 100
	}
	return v, true
}

// Collect returns one set of samples and a list of collectors that failed.
func (c *Collector) Collect(ctx context.Context) ([]telemetry.Sample, []telemetry.PartialInfo) {
	now := time.Now().UTC()
	var out []telemetry.Sample
	var partial []telemetry.PartialInfo
	add := func(m, s string, v float64) {
		out = append(out, telemetry.Sample{Metric: m, Series: s, TS: now, Value: v})
	}
	fail := func(collector string, err error) {
		partial = append(partial, telemetry.PartialInfo{Collector: collector, Error: err.Error()})
	}
	elapsed := now.Sub(c.prevAt).Seconds()
	first := c.prevAt.IsZero()

	// CPU (total and per core) from time deltas.
	if total, err := cpu.TimesWithContext(ctx, false); err == nil && len(total) == 1 {
		if c.prevTotal != nil {
			if v, ok := pct(*c.prevTotal, total[0]); ok {
				add("cpu.utilization", "", v)
				_, t0 := busy(*c.prevTotal)
				_, t1 := busy(total[0])
				if d := t1 - t0; d > 0 {
					add("cpu.iowait", "", (total[0].Iowait-c.prevTotal.Iowait)/d*100)
					add("cpu.steal", "", (total[0].Steal-c.prevTotal.Steal)/d*100)
				}
			}
		}
		t := total[0]
		c.prevTotal = &t
	} else if err != nil {
		fail("cpu", err)
	}
	if per, err := cpu.TimesWithContext(ctx, true); err == nil {
		if len(c.prevCPU) == len(per) {
			for i := range per {
				if v, ok := pct(c.prevCPU[i], per[i]); ok {
					add("cpu.core.utilization", fmt.Sprintf("core=%d", i), v)
				}
			}
		}
		c.prevCPU = per
	}
	if runtime.GOOS != "windows" {
		if l, err := load.AvgWithContext(ctx); err == nil {
			add("cpu.load1", "", l.Load1)
			add("cpu.load5", "", l.Load5)
			add("cpu.load15", "", l.Load15)
		}
	}

	// Memory.
	if vm, err := mem.VirtualMemoryWithContext(ctx); err == nil {
		add("memory.total_bytes", "", float64(vm.Total))
		add("memory.available_bytes", "", float64(vm.Available))
		add("memory.used_bytes", "", float64(vm.Total-vm.Available))
		if vm.Total > 0 {
			add("memory.utilization", "", float64(vm.Total-vm.Available)/float64(vm.Total)*100)
		}
	} else {
		fail("memory", err)
	}
	if sw, err := mem.SwapMemoryWithContext(ctx); err == nil && sw.Total > 0 {
		add("memory.swap_utilization", "", sw.UsedPercent)
	}

	// Filesystems: every real mounted volume, not just the system disk.
	if parts, err := disk.PartitionsWithContext(ctx, false); err == nil {
		seen := map[string]bool{}
		for _, p := range parts {
			if pseudoFS[p.Fstype] || seen[p.Mountpoint] || c.excluded(p.Mountpoint) {
				continue
			}
			seen[p.Mountpoint] = true
			u, err := disk.UsageWithContext(ctx, p.Mountpoint)
			if err != nil || u.Total == 0 {
				continue
			}
			s := "mount=" + p.Mountpoint
			add("disk.total_bytes", s, float64(u.Total))
			add("disk.used_bytes", s, float64(u.Used))
			add("disk.free_bytes", s, float64(u.Free))
			add("disk.utilization", s, u.UsedPercent)
		}
	} else {
		fail("filesystems", err)
	}

	// Disk I/O rates (aggregate across devices).
	if io, err := disk.IOCountersWithContext(ctx); err == nil {
		if !first && elapsed > 0 && c.prevDisk != nil {
			var rb, wb, ro, wo float64
			for name, cur := range io {
				if prev, ok := c.prevDisk[name]; ok && cur.ReadBytes >= prev.ReadBytes && cur.WriteBytes >= prev.WriteBytes {
					rb += float64(cur.ReadBytes - prev.ReadBytes)
					wb += float64(cur.WriteBytes - prev.WriteBytes)
					ro += float64(cur.ReadCount - prev.ReadCount)
					wo += float64(cur.WriteCount - prev.WriteCount)
				}
			}
			add("disk.read_bytes_per_sec", "", rb/elapsed)
			add("disk.write_bytes_per_sec", "", wb/elapsed)
			add("disk.read_ops_per_sec", "", ro/elapsed)
			add("disk.write_ops_per_sec", "", wo/elapsed)
		}
		c.prevDisk = io
	}

	// Network rates.
	if nics, err := gnet.IOCountersWithContext(ctx, false); err == nil && len(nics) == 1 {
		cur := nics[0]
		if p := c.prevNet; p != nil && !first && elapsed > 0 && cur.BytesRecv >= p.BytesRecv && cur.BytesSent >= p.BytesSent {
			add("net.in_bytes_per_sec", "", float64(cur.BytesRecv-p.BytesRecv)/elapsed)
			add("net.out_bytes_per_sec", "", float64(cur.BytesSent-p.BytesSent)/elapsed)
			add("net.in_packets_per_sec", "", float64(cur.PacketsRecv-p.PacketsRecv)/elapsed)
			add("net.out_packets_per_sec", "", float64(cur.PacketsSent-p.PacketsSent)/elapsed)
			add("net.errors_per_sec", "", float64((cur.Errin+cur.Errout)-(p.Errin+p.Errout))/elapsed)
			add("net.drops_per_sec", "", float64((cur.Dropin+cur.Dropout)-(p.Dropin+p.Dropout))/elapsed)
		}
		c.prevNet = &cur
	}
	if runtime.GOOS == "linux" {
		if pc, err := gnet.ProtoCountersWithContext(ctx, []string{"tcp"}); err == nil && len(pc) == 1 {
			if v, ok := pc[0].Stats["CurrEstab"]; ok {
				add("net.tcp_established", "", float64(v))
			}
		}
	}
	if up, err := host.UptimeWithContext(ctx); err == nil {
		add("system.uptime_seconds", "", float64(up))
	}
	c.prevAt = now
	return out, partial
}

func (c *Collector) excluded(mount string) bool {
	for _, m := range c.ExcludeMounts {
		if m == mount || (strings.HasSuffix(m, "*") && strings.HasPrefix(mount, strings.TrimSuffix(m, "*"))) {
			return true
		}
	}
	return false
}

// SelfStats reports the agent's own resource usage.
func (c *Collector) SelfStats() (cpuPct float64, rss uint64) {
	if c.self == nil {
		return 0, 0
	}
	cpuPct, _ = c.self.Percent(0)
	if mi, err := c.self.MemoryInfo(); err == nil {
		rss = mi.RSS
	}
	return cpuPct, rss
}
