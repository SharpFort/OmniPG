package main

import "testing"

func TestGetEnv_DefaultValue(t *testing.T) {
	// 临时清除环境变量
	key := "TEST_VAR_NOT_SET"
	val := getEnv(key, "default_val")
	if val != "default_val" {
		t.Errorf("应返回默认值, 得到 %q", val)
	}
}

func TestGetEnv_EnvValue(t *testing.T) {
	key := "TEST_VAR_EXISTS"
	envVal := "custom_value"
	t.Setenv(key, envVal)
	val := getEnv(key, "default")
	if val != envVal {
		t.Errorf("应返回环境变量值 %q, 得到 %q", envVal, val)
	}
}
