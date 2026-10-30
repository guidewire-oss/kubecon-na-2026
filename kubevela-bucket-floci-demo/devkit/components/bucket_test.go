package components

import (
	"reflect"
	"testing"

	"github.com/kubecon-na-2026/kubevela-bucket-floci-demo/devkit/internal/cuetest"
	"github.com/kubecon-na-2026/kubevela-bucket-floci-demo/devkit/internal/paramcheck"
	"github.com/oam-dev/kubevela/pkg/cue/definition/health"
	"github.com/oam-dev/kubevela/pkg/definition/defkit"
)

// stage is the KubeVela context of a component deployed to the aws-devkit stage.
var stage = map[string]any{"name": "product-images", "namespace": "aws-devkit"}

func render(t *testing.T, def cuetest.Definition, props BucketProperties) cuetest.Rendered {
	t.Helper()
	out, err := cuetest.Render(def, stage, props)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// ./demo.sh applies both bucket-aws-cue and bucket-aws-devkit, and the promotion
// swaps one for the other, so they must render the same resources.
func TestBucketAWSMatchesCUE(t *testing.T) {
	cue := cuetest.ReadDefinition(t, "components/bucket-aws-cue.cue")
	for _, props := range []BucketProperties{
		{Name: "product-images"},
		{Name: "product-images", Region: "eu-west-1", Versioning: true, ProjectName: "catalog"},
	} {
		want, got := render(t, cue, props), render(t, BucketAWS(), props)
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%+v: Go and CUE differ\n go: %#v\ncue: %#v", props, got, want)
		}
	}
}

func TestBucketAWSRendersBucket(t *testing.T) {
	out := render(t, BucketAWS(), BucketProperties{Name: "product-images", Versioning: true})

	for path, want := range map[string]any{
		"metadata.name":                 "product-images-aws-devkit",
		"metadata.labels":               map[string]any{"app.kubernetes.io/part-of": "kubecon-na-2026"},
		"spec.forProvider.region":       "us-west-2",
		"spec.forProvider.forceDestroy": true,
		"spec.providerConfigRef.name":   "default",
		"metadata.annotations":          map[string]any{"crossplane.io/external-name": "product-images-aws-devkit"},
	} {
		if got := cuetest.Get(out.Output, path); !reflect.DeepEqual(got, want) {
			t.Errorf("%s = %#v, want %#v", path, got, want)
		}
	}
	versioning, _ := out.Outputs["versioning"].(map[string]any)
	if got := cuetest.Get(versioning, "spec.forProvider.bucketRef.name"); got != "product-images-aws-devkit" {
		t.Errorf("versioning bucketRef = %v, want the bucket", got)
	}
}

func TestBucketAWSVersioningIsOptional(t *testing.T) {
	if out := render(t, BucketAWS(), BucketProperties{Name: "product-images"}); len(out.Outputs) != 0 {
		t.Errorf("outputs without versioning = %#v, want none", out.Outputs)
	}
}

func TestBucketGCPMapsRegionToLocation(t *testing.T) {
	for _, region := range Regions {
		out := render(t, BucketGCP(), BucketProperties{Name: "product-images", Region: region, Versioning: true})
		if got := cuetest.Get(out.Output, "spec.forProvider.location"); got != gcsLocations[region] {
			t.Errorf("%s: location = %v, want %s", region, got, gcsLocations[region])
		}
		if got := cuetest.Get(out.Output, "spec.forProvider.versioning.enabled"); got != true {
			t.Errorf("%s: versioning.enabled = %v, want true", region, got)
		}
	}
}

func TestBucketGCPRejectsUnmappedRegion(t *testing.T) {
	if err := cuetest.ValidateProperties(BucketGCP(), BucketProperties{Name: "b", Region: "af-south-1"}); err == nil {
		t.Error("accepted region af-south-1, which has no GCS location")
	}
}

// Every bucket component, in Go or CUE, takes exactly BucketProperties.
func TestBucketsShareOneInterface(t *testing.T) {
	for _, def := range []*defkit.ComponentDefinition{BucketAWS(), BucketGCP()} {
		for _, d := range paramcheck.Diff(def.GetParams(), BucketProperties{}) {
			t.Errorf("%s: %s", def.DefName(), d)
		}
	}
}

// statusOf runs a component's health policy and status message through
// KubeVela's own evaluator, as the controller does on each reconcile.
func statusOf(t *testing.T, def *defkit.ComponentDefinition, status map[string]any) *health.StatusResult {
	t.Helper()
	output := map[string]any{"metadata": map[string]any{"name": "product-images-aws-devkit"}}
	if status != nil {
		output["status"] = status
	}
	got, err := health.GetStatus(map[string]any{"output": output}, &health.StatusRequest{
		Health: def.GetHealthPolicy(),
		Custom: def.GetCustomStatus(),
	})
	if err != nil {
		t.Fatalf("%s: %v", def.DefName(), err)
	}
	return got
}

func TestBucketStatus(t *testing.T) {
	ready := map[string]any{"conditions": []any{map[string]any{"type": "Ready", "status": "True"}}}
	creating := map[string]any{"conditions": []any{map[string]any{"type": "Ready", "status": "False"}}}
	tests := []struct {
		name        string
		status      map[string]any
		wantHealthy bool
		wantMessage string
	}{
		{"no status yet", nil, false, "Provisioning bucket - Ready: Unknown"},
		{"creating", creating, false, "Provisioning bucket - Ready: False"},
		{"ready", ready, true, "Bucket product-images-aws-devkit ready"},
	}
	for _, def := range []*defkit.ComponentDefinition{BucketAWS(), BucketGCP()} {
		for _, tt := range tests {
			got := statusOf(t, def, tt.status)
			if got.Healthy != tt.wantHealthy || got.Message != tt.wantMessage {
				t.Errorf("%s %s: healthy %v message %q, want %v %q",
					def.DefName(), tt.name, got.Healthy, got.Message, tt.wantHealthy, tt.wantMessage)
			}
		}
	}
}
