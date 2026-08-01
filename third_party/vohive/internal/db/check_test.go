package db

import "testing"

func TestCheckSchema(t *testing.T) {
	openTestDB(t)
	var m []map[string]interface{}
	if err := DB.Raw("PRAGMA table_info(devices)").Scan(&m).Error; err != nil {
		t.Fatal(err)
	}
	foundIMEI := false
	for _, row := range m {
		if row["name"] == "imei" {
			foundIMEI = true
			break
		}
	}
	if !foundIMEI {
		t.Fatalf("devices schema columns=%v, want imei", m)
	}
}
