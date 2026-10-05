package config

import "testing"

func TestAllowRenderFileProxyDefaultsOff(t *testing.T) {
	t.Setenv("ALLOW_RENDER_FILE_PROXY", "")
	if Load().AllowRenderFileProxy {
		t.Fatal("unset proxy flag must stay false")
	}
	t.Setenv("ALLOW_RENDER_FILE_PROXY", "false")
	if Load().AllowRenderFileProxy {
		t.Fatal("false must disable the Render file proxy")
	}
	t.Setenv("ALLOW_RENDER_FILE_PROXY", "true")
	if !Load().AllowRenderFileProxy {
		t.Fatal("true must allow the Render file proxy")
	}
}
