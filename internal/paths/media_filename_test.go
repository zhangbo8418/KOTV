package paths

import "testing"

func TestIsMediaFilename(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		want bool
	}{
		{"a.mp4", true},
		{"A.MKV", true},
		{"clip.m2ts", true},
		{"readme.txt", false},
		{"noext", false},
		{".hidden.mp4", true},
	}
	for _, c := range cases {
		if got := IsMediaFilename(c.name); got != c.want {
			t.Fatalf("IsMediaFilename(%q)=%v want %v", c.name, got, c.want)
		}
	}
}
