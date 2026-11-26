//go:build !windows

package winime

import (
	"sync"

	"github.com/wmyung/tailime/windows/internal/core"
)

type Status struct {
	Language         core.InputLanguage
	SourceID         string
	HKL              uintptr
	Reliable         bool
	SecureDesktop    bool
	ElevationBlocked bool
}

type Engine struct {
	mu   sync.Mutex
	lang core.InputLanguage
}

func NewEngine(syntheticMarker uintptr) *Engine {
	return &Engine{lang: core.LangEnglish}
}

func (e *Engine) LastElevationBlocked() bool { return false }
func (e *Engine) SelfElevated() bool         { return false }
func (e *Engine) Preempt()                   {}

func (e *Engine) CurrentStatus() Status {
	e.mu.Lock()
	defer e.mu.Unlock()
	return Status{Language: e.lang, SourceID: "stub-" + string(e.lang), Reliable: true}
}

func (e *Engine) SwitchTo(target core.InputLanguage) Status {
	e.mu.Lock()
	if target == core.LangKorean || target == core.LangEnglish {
		e.lang = target
	}
	l := e.lang
	e.mu.Unlock()
	return Status{Language: l, SourceID: "stub-" + string(l), Reliable: true}
}

func (e *Engine) Toggle() Status {
	cur := e.CurrentStatus()
	return e.SwitchTo(cur.Language.Toggled())
}
