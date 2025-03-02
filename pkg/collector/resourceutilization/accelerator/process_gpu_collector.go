/*
Copyright 2021.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package accelerator

import (
	"fmt"
	"os"
	"time"

	"github.com/sustainable-computing-io/kepler/pkg/cgroup"
	"github.com/sustainable-computing-io/kepler/pkg/collector/stats"
	"github.com/sustainable-computing-io/kepler/pkg/config"
	"github.com/sustainable-computing-io/kepler/pkg/libvirt"
	"github.com/sustainable-computing-io/kepler/pkg/sensors/accelerator/gpu"
	gpu_source "github.com/sustainable-computing-io/kepler/pkg/sensors/accelerator/gpu/source"
	"k8s.io/klog/v2"

	"github.com/sustainable-computing-io/kepler/pkg/utils"
)

const (
	procPath string = "/proc/%d/cgroup"
)

var (
	// lastUtilizationTimestamp represents the CPU timestamp in microseconds at which utilization samples were last read
	lastUtilizationTimestamp time.Time = time.Now()
)

// updateProcessBPFMetrics reads the BPF tables with process/pid/cgroupid metrics (CPU time, available HW counters)
func UpdateNodeGPUUtilizationMetrics(processStats map[uint64]*stats.ProcessStats) {
	var err error
	var processesUtilization map[uint32]gpu_source.ProcessUtilizationSample
	// calculate the gpu's processes energy consumption for each gpu
	for _, device := range gpu.GetGpus() {
		if processesUtilization, err = gpu.GetProcessResourceUtilizationPerDevice(device, time.Since(lastUtilizationTimestamp)); err != nil {
			klog.Infoln(err)
			continue
		}

		for pid, processUtilization := range processesUtilization {
			uintPid := uint64(pid)
			// if the process was not indentified by the bpf metrics, create a new metric object
			if _, exist := processStats[uintPid]; !exist {
				command := getProcessCommand(uintPid)
				containerID := utils.SystemProcessName

				// if the pid is within a container, it will have an container ID
				if config.IsExposeContainerStatsEnabled() {
					if containerID, err = cgroup.GetContainerIDFromPID(uintPid); err != nil {
						klog.V(6).Infof("failed to resolve container for Pid %v (command=%s): %v, set containerID=%s", pid, command, err, containerID)
					}
				}

				// if the pid is within a VM, it will have an VM ID
				vmID := utils.EmptyString
				if config.IsExposeVMStatsEnabled() {
					if config.IsExposeVMStatsEnabled() {
						vmID, err = libvirt.GetVMID(uintPid)
						if err != nil {
							klog.V(6).Infof("failed to resolve VM ID for PID %v (command=%s): %v", pid, command, err)
						}
					}
				}
				processStats[uintPid] = stats.NewProcessStats(uintPid, uint64(0), containerID, vmID, command)
			}
			processStats[uintPid].ResourceUsage[config.GPUSMUtilization].AddDeltaStat(utils.GenericSocketID, uint64(processUtilization.SmUtil))
			processStats[uintPid].ResourceUsage[config.GPUMemUtilization].AddDeltaStat(utils.GenericSocketID, uint64(processUtilization.MemUtil))
		}
	}

	lastUtilizationTimestamp = time.Now()
}

func getProcessCommand(pid uint64) string {
	fileName := fmt.Sprintf(procPath, pid)
	// Read the file
	comm, err := os.ReadFile(fileName)
	if err != nil {
		return ""
	}
	return string(comm)
}
