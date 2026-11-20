"ate-job": {
	type: "component"
	annotations: {}
	labels: {}
	description: "A Job whose component is healthy only once it has completed. Used for idempotent bootstrap steps that later components depend on."
	attributes: {
		workload: definition: {
			apiVersion: "batch/v1"
			kind:       "Job"
		}
		status: {
			healthPolicy: #"""
				isHealth: context.output.status.succeeded != _|_ && context.output.status.succeeded >= 1
				"""#
		}
	}
}

template: {
	output: {
		apiVersion: "batch/v1"
		kind:       "Job"
		if parameter.namespace != _|_ {
			metadata: namespace: parameter.namespace
		}
		spec: {
			backoffLimit: parameter.backoffLimit
			template: {
				metadata: labels: "app.oam.dev/component": context.name
				spec: {
					restartPolicy:      "OnFailure"
					serviceAccountName: parameter.serviceAccountName
					if parameter.initContainers != _|_ {
						initContainers: parameter.initContainers
					}
					containers: parameter.containers
					if parameter.volumes != _|_ {
						volumes: parameter.volumes
					}
				}
			}
		}
	}
	parameter: {
		// +usage=Namespace of the Job; defaults to the Application's.
		namespace?: string
		// +usage=ServiceAccount the Job runs as.
		serviceAccountName: string
		// +usage=Retries before the Job is marked failed.
		backoffLimit: *6 | int
		// +usage=Init containers, run in order before the containers.
		initContainers?: [...{...}]
		// +usage=Containers of the Job.
		containers: [...{...}]
		// +usage=Pod volumes.
		volumes?: [...{...}]
	}
}
