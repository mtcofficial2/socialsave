package jobs

import (
	"testing"
	"time"
)

func TestPurgesFailedJobs(t *testing.T) {
	store := NewStore(time.Second)
	job := store.Create()
	store.mu.Lock()
	stored := store.all[job.ID]
	stored.State = "failed"
	stored.CreatedAt = time.Unix(0, 0)
	store.mu.Unlock()
	store.Purge()
	if _, ok := store.Get(job.ID); ok {
		t.Fatal("expected failed job to be purged")
	}
}
