package catalog

import (
	"testing"

	"github.com/split-route/core/rules"
)

func TestCatalog(t *testing.T) {
	seen := map[string]bool{}
	for _, i := range Catalog {
		switch {
		case seen[i.Name]:
			t.Errorf("%s listed twice", i.Name)
		case i.Title == "" || i.Description == "":
			t.Errorf("%s: title and description are required", i.Name)
		case i.Action != rules.Direct && i.Action != rules.Block && i.Action != rules.Tunnel:
			t.Errorf("%s: action %q", i.Name, i.Action)
		}
		seen[i.Name] = true
		if Describe(i.Name) != i {
			t.Errorf("Describe(%s) = %+v", i.Name, Describe(i.Name))
		}
	}
	if d := Describe("not-in-catalog"); d.Title != "not-in-catalog" || d.Action != rules.Direct {
		t.Errorf("unknown list: %+v", d)
	}
}
