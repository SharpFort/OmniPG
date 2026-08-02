package syncer

import (
	"database/sql"
	"fmt"
	"strings"
	"testing"

	"casbin-syncer/internal/database"
)

// ==============================================================================
// Mock 实现
// ==============================================================================

// mockStore 模拟 database.DBPolicyStore
type mockStore struct {
	policies []database.PolicyRow
}

func (m *mockStore) FetchPolicies() ([]database.PolicyRow, error) {
	return m.policies, nil
}

func (m *mockStore) CalcPolicyHash() (string, error) {
	return fmt.Sprintf("%d", len(m.policies)), nil
}

// mockAPISIXClient 模拟 APISIX HTTP 客户端
type mockAPISIXClient struct {
	policy    string
	getErr    error
	putErr    error
	callCount int
}

func (m *mockAPISIXClient) GetPolicy() (string, error) {
	m.callCount++
	return m.policy, m.getErr
}

func (m *mockAPISIXClient) PutPolicy(model, policy string) error {
	m.callCount++
	m.policy = policy
	return m.putErr
}

type urlError struct {
	msg string
}

func (e *urlError) Error() string { return e.msg }

// ==============================================================================
// 测试 formatToCSV（修复 P0-1 验证）
// ==============================================================================

func TestFormatToCSV_Empty(t *testing.T) {
	result := formatToCSV([]database.PolicyRow{})
	if result != "" {
		t.Errorf("空策略应返回空串, 得到 %q", result)
	}
}

func TestFormatToCSV_SingleRow(t *testing.T) {
	row := database.PolicyRow{
		Ptype: "p",
		V0:    sql.NullString{String: "role_admin", Valid: true},
		V1:    sql.NullString{String: "/sys_user", Valid: true},
		V2:    sql.NullString{String: "GET", Valid: true},
	}
	result := formatToCSV([]database.PolicyRow{row})
	expected := "p,role_admin,/sys_user,GET"
	if result != expected {
		t.Errorf("单行策略格式错误\n期望: %q\n实际: %q", expected, result)
	}
}

func TestFormatToCSV_NoTrailingNewline(t *testing.T) {
	// P0-1 验证：formatToCSV 尾部不应有 \n（与 SQL string_agg 行为一致）
	rows := []database.PolicyRow{
		{
			Ptype: "p",
			V0:    sql.NullString{String: "role_admin", Valid: true},
			V1:    sql.NullString{String: "/sys_user", Valid: true},
			V2:    sql.NullString{String: "GET", Valid: true},
		},
		{
			Ptype: "p",
			V0:    sql.NullString{String: "role_admin", Valid: true},
			V1:    sql.NullString{String: "/sys_role", Valid: true},
			V2:    sql.NullString{String: "GET", Valid: true},
		},
	}
	result := formatToCSV(rows)

	if strings.HasSuffix(result, "\n") {
		t.Errorf("formatToCSV 不应有尾部换行符, 得到 %q", result)
	}

	expected := "p,role_admin,/sys_user,GET\np,role_admin,/sys_role,GET"
	if result != expected {
		t.Errorf("多行策略格式错误\n期望: %q\n实际: %q", expected, result)
	}
}

func TestFormatToCSV_WithNullColumns(t *testing.T) {
	// 测试 NULL 列（Valid=false 的 sql.NullString）
	row := database.PolicyRow{
		Ptype: "p",
		V0:    sql.NullString{String: "role_admin", Valid: true},
		V1:    sql.NullString{String: "/sys_user", Valid: true},
		V2:    sql.NullString{String: "GET", Valid: true},
		V3:    sql.NullString{Valid: false},
		V4:    sql.NullString{Valid: false},
		V5:    sql.NullString{Valid: false},
	}
	result := formatToCSV([]database.PolicyRow{row})
	// NULL 列不应出现在输出中（被 lastValidIdx 截断）
	expected := "p,role_admin,/sys_user,GET"
	if result != expected {
		t.Errorf("NULL 列截断错误\n期望: %q\n实际: %q", expected, result)
	}
}

func TestFormatToCSV_AllNullColumns(t *testing.T) {
	// 所有 V 列都为 NULL，只保留 ptype
	row := database.PolicyRow{
		Ptype: "p",
		V0:    sql.NullString{Valid: false},
		V1:    sql.NullString{Valid: false},
		V2:    sql.NullString{Valid: false},
		V3:    sql.NullString{Valid: false},
		V4:    sql.NullString{Valid: false},
		V5:    sql.NullString{Valid: false},
	}
	result := formatToCSV([]database.PolicyRow{row})
	expected := "p"
	if result != expected {
		t.Errorf("全 NULL 列只应保留 ptype\n期望: %q\n实际: %q", expected, result)
	}
}

// 验证与 PostgreSQL string_agg 一致性
// PG: string_agg(concat_ws(',', ptype, v0, v1, ...), E'\n') 不会在末尾加 \n
func TestFormatToCSV_ConsistencyWithStringAgg(t *testing.T) {
	rows := []database.PolicyRow{
		{Ptype: "p", V0: sql.NullString{String: "admin", Valid: true}, V1: sql.NullString{String: "/api", Valid: true}},
		{Ptype: "p", V0: sql.NullString{String: "user", Valid: true}, V1: sql.NullString{String: "/public", Valid: true}},
		{Ptype: "p", V0: sql.NullString{String: "guest", Valid: true}, V1: sql.NullString{String: "/health", Valid: true}},
	}
	result := formatToCSV(rows)
	lines := strings.Split(result, "\n")
	if len(lines) != 3 {
		t.Errorf("应有 3 行, 得到 %d 行: %q", len(lines), result)
	}
	lastLine := lines[len(lines)-1]
	if lastLine == "" {
		t.Errorf("最后一行不应该是空字符串（说明有尾部换行）: %q", result)
	}
}

// ==============================================================================
// 测试 Sync() 冷启动优化（P2-3 验证）
// ==============================================================================

func TestSync_SkipWhenEmpty(t *testing.T) {
	// 空策略表时应跳过同步（不调用 APISIX PUT）
	mockClient := &mockAPISIXClient{}
	s := NewSyncer(nil, &mockStore{}, mockClient)

	err := s.Sync()
	if err != nil {
		t.Errorf("空策略不应返回错误: %v", err)
	}
	if mockClient.callCount != 0 {
		t.Errorf("空策略不应调用 APISIX，实际调用 %d 次", mockClient.callCount)
	}
}

func TestSync_NormalSync(t *testing.T) {
	mockClient := &mockAPISIXClient{}
	store := &mockStore{policies: []database.PolicyRow{
		{Ptype: "p", V0: sql.NullString{String: "admin", Valid: true}},
	}}
	s := NewSyncer(nil, store, mockClient)

	err := s.Sync()
	if err != nil {
		t.Errorf("同步失败: %v", err)
	}
	if mockClient.callCount != 1 {
		t.Errorf("应调用 APISIX 1 次, 实际 %d 次", mockClient.callCount)
	}
}

// ==============================================================================
// 测试 Reconcile 网络错误处理（P1-5 验证）
// ==============================================================================

func TestReconcile_NetworkErrorSkipsSync(t *testing.T) {
	// 网络错误时不应触发全量同步
	mockClient := &mockAPISIXClient{
		getErr: &urlError{"connection refused: localhost:9180"},
	}
	store := &mockStore{policies: []database.PolicyRow{
		{Ptype: "p", V0: sql.NullString{String: "admin", Valid: true}},
	}}
	s := NewSyncer(nil, store, mockClient)

	err := s.Reconcile()
	if err != nil {
		t.Errorf("网络错误应跳过对账而不报错: %v", err)
	}
	if mockClient.callCount != 1 {
		t.Errorf("网络错误不应触发全量同步（仅 GetPolicy 1 次）, 实际 %d 次", mockClient.callCount)
	}
}

func TestReconcile_NonNetworkErrorTriggersSync(t *testing.T) {
	// 非网络错误（如 404）应触发全量同步
	mockClient := &mockAPISIXClient{
		getErr: &urlError{"APISIX 返回 404: not found"},
	}
	store := &mockStore{policies: []database.PolicyRow{
		{Ptype: "p", V0: sql.NullString{String: "admin", Valid: true}},
	}}
	s := NewSyncer(nil, store, mockClient)

	err := s.Reconcile()
	if err != nil {
		t.Errorf("非网络错误应触发全量同步: %v", err)
	}
	if mockClient.callCount != 2 {
		t.Errorf("应触发全量同步（GetPolicy + PutPolicy 各 1 次）, 实际 %d 次", mockClient.callCount)
	}
}

func TestIsNetworkError(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{"connection refused", &urlError{"connection refused: localhost:9180"}, true},
		{"timeout", &urlError{"i/o timeout"}, true},
		{"no such host", &urlError{"no such host: apisix"}, true},
		{"deadline exceeded", &urlError{"context deadline exceeded"}, true},
		{"json error", &urlError{"invalid JSON response"}, false},
		{"404 not found", &urlError{"APISIX 返回 404"}, false},
		{"nil error", nil, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isNetworkError(tt.err)
			if got != tt.want {
				t.Errorf("isNetworkError(%v) = %v, want %v", tt.err, got, tt.want)
			}
		})
	}
}

// ==============================================================================
// 测试 truncate 函数
// ==============================================================================

func TestTruncate(t *testing.T) {
	tests := []struct {
		input  string
		maxLen int
		want   string
	}{
		{"abcdef", 4, "abcd"},
		{"ab", 4, "ab"},
		{"", 4, ""},
		{"hello", 5, "hello"},
	}
	for _, tt := range tests {
		got := truncate(tt.input, tt.maxLen)
		if got != tt.want {
			t.Errorf("truncate(%q, %d) = %q, want %q", tt.input, tt.maxLen, got, tt.want)
		}
	}
}

// ==============================================================================
// Benchmark 测试
// ==============================================================================

func BenchmarkFormatToCSV(b *testing.B) {
	// 生成 1000 行模拟策略
	rows := make([]database.PolicyRow, 1000)
	for i := 0; i < 1000; i++ {
		rows[i] = database.PolicyRow{
			Ptype: "p",
			V0:    sql.NullString{String: fmt.Sprintf("role_%d", i), Valid: true},
			V1:    sql.NullString{String: fmt.Sprintf("/api/resource_%d", i), Valid: true},
			V2:    sql.NullString{String: "GET", Valid: true},
		}
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = formatToCSV(rows)
	}
}

func BenchmarkFormatToCSV_Large(b *testing.B) {
	// 生成 50000 行模拟策略（大规模）
	rows := make([]database.PolicyRow, 50000)
	for i := 0; i < 50000; i++ {
		rows[i] = database.PolicyRow{
			Ptype: "p",
			V0:    sql.NullString{String: fmt.Sprintf("role_%d", i), Valid: true},
			V1:    sql.NullString{String: fmt.Sprintf("/api/resource_%d", i), Valid: true},
			V2:    sql.NullString{String: "POST", Valid: true},
		}
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = formatToCSV(rows)
	}
}
