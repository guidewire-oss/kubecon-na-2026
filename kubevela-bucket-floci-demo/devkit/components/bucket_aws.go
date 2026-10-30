package components

import "github.com/oam-dev/kubevela/pkg/definition/defkit"

// BucketAWSType is the component type an Application refers to.
const BucketAWSType = "bucket-aws-devkit"

// BucketAWS is the Go version of
// ../../definitions/components/bucket-aws-cue.cue: an S3 bucket that
// Crossplane's provider-aws-s3 creates in Floci.
func BucketAWS() *defkit.ComponentDefinition {
	p := newBucketParams()
	return defkit.NewComponent(BucketAWSType).
		Description("S3 bucket created by Crossplane in Floci. Named <name>-<namespace>.").
		Workload("s3.aws.upbound.io/v1beta1", "Bucket").
		Params(p.all()...).
		Template(p.renderAWS).
		HealthPolicyExpr(defkit.Health().Condition("Ready").IsTrue()).
		CustomStatus(bucketStatus)
}

func (p bucketParams) renderAWS(tpl *defkit.Template) {
	tpl.Output(p.newBucketResource("s3.aws.upbound.io/v1beta1", "Bucket").
		Set("spec.forProvider.region", p.region))

	// S3 versioning is a resource of its own.
	tpl.OutputsIf(p.versioning.IsTrue(), "versioning",
		defkit.NewResource("s3.aws.upbound.io/v1beta2", "BucketVersioning").
			Set("metadata.name", p.bucketName()).
			Set("spec.forProvider.region", p.region).
			Set("spec.forProvider.bucketRef.name", p.bucketName()).
			Set("spec.forProvider.versioningConfiguration.status", defkit.Lit("Enabled")).
			Set("spec.providerConfigRef.name", defkit.Lit("default")))
}

// bucketStatus names the bucket once it is ready, and shows Crossplane's
// Ready condition until then. It is CUE rather than defkit's status builder,
// whose condition lookups fail while the bucket has no status.
const bucketStatus = `ready: *"Unknown" | string
for c in *context.output.status.conditions | [] {
	if c.type == "Ready" {
		ready: c.status
	}
}
if context.status.healthy {
	message: "Bucket \(context.output.metadata.name) ready"
}
if !context.status.healthy {
	message: "Provisioning bucket - Ready: \(ready)"
}`

func init() {
	defkit.Register(BucketAWS())
}
