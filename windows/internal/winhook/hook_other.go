//go:build !windows

package winhook

import "sync/atomic"

type Snapshot struct {
	Enabled            bool
	Paused             bool
	RemoteSessionReady bool
	TriggerHangulKey   bool
	TriggerRightAltTap bool
	TriggerCtrlSpace   bool
	TriggerShiftSpace  bool
	TriggerF18F19      bool
}

type TriggerEvent struct {
	VKCode uint32
	Label  string
}

type Controller struct {
	snap                atomic.Pointer[Snapshot]
	OnRemoteTrigger     func(TriggerEvent)
	OnForegroundChanged func()
}

func NewController(syntheticMarker uintptr) *Controller {
	c := &Controller{}
	s := Snapshot{Enabled: true, TriggerHangulKey: true, TriggerF18F19: true}
	c.snap.Store(&s)
	return c
}

func (c *Controller) UpdateSnapshot(s Snapshot) { cp := s; c.snap.Store(&cp) }
func (c *Controller) IsActive() bool            { return false }
func (c *Controller) RequestHookReinstall()     {}
func (c *Controller) Start()                    {}
func (c *Controller) Stop()                     {}
