package database

import (
	"database/sql"
)

// PolicyRow 表示 casbin_rule 表的一行
type PolicyRow struct {
	Ptype string
	V0    sql.NullString
	V1    sql.NullString
	V2    sql.NullString
	V3    sql.NullString
	V4    sql.NullString
	V5    sql.NullString
}

// DBPolicyStore 定义数据库策略操作接口
type DBPolicyStore interface {
	FetchPolicies() ([]PolicyRow, error)
	CalcPolicyHash() (string, error)
}

// PostgresStore 实现 DBPolicyStore
type PostgresStore struct {
	db *sql.DB
}

func NewPostgresStore(db *sql.DB) *PostgresStore {
	return &PostgresStore{db: db}
}

// FetchPolicies 从 casbin_rule 表读取所有 p 规则
// 修复 N-1: 添加 WHERE ptype='p' 过滤
func (s *PostgresStore) FetchPolicies() ([]PolicyRow, error) {
	query := `SELECT ptype, v0, v1, v2, v3, v4, v5 FROM casbin_rule WHERE ptype = 'p' ORDER BY ptype, v0, v1, v2, v3, v4, v5;`
	rows, err := s.db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var result []PolicyRow
	for rows.Next() {
		var r PolicyRow
		if err := rows.Scan(&r.Ptype, &r.V0, &r.V1, &r.V2, &r.V3, &r.V4, &r.V5); err != nil {
			return nil, err
		}
		result = append(result, r)
	}
	return result, rows.Err()
}

// CalcPolicyHash 计算数据库侧策略的 SHA256 指纹
func (s *PostgresStore) CalcPolicyHash() (string, error) {
	var dbHash string
	query := `SELECT COALESCE(encode(digest(string_agg(
		concat_ws(',', ptype, v0, v1, v2, v3, v4, v5), E'\n'
		ORDER BY ptype, v0, v1, v2, v3, v4, v5
	), 'sha256'), 'hex'), '') FROM casbin_rule WHERE ptype = 'p';`

	err := s.db.QueryRow(query).Scan(&dbHash)
	return dbHash, err
}
