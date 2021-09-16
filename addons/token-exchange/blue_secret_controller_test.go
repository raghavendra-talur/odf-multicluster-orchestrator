package addons

import (
	"context"
	"testing"
	"time"

	"github.com/openshift/library-go/pkg/operator/events/eventstesting"
	"github.com/stretchr/testify/assert"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	kubeinformers "k8s.io/client-go/informers"
	kubefake "k8s.io/client-go/kubernetes/fake"
)

func getFakeBlueTokenExchangeController(
	t *testing.T,
	hubResources,
	spokeResources []runtime.Object) *blueSecretTokenExchangeAgentController {

	fakeHubKubeClient := kubefake.NewSimpleClientset(hubResources...)
	fakeSpokeKubeClient := kubefake.NewSimpleClientset(spokeResources...)
	fakeHubInformerFactory := kubeinformers.NewSharedInformerFactory(fakeHubKubeClient, time.Minute*10)
	fakeSpokeInformerFactory := kubeinformers.NewSharedInformerFactory(fakeSpokeKubeClient, time.Minute*10)

	secretStore := fakeSpokeInformerFactory.Core().V1().Secrets().Informer().GetStore()
	for _, object := range spokeResources {
		err := secretStore.Add(object)
		assert.NoError(t, err)
	}

	return &blueSecretTokenExchangeAgentController{
		hubKubeClient:     fakeHubKubeClient,
		spokeKubeClient:   fakeSpokeKubeClient,
		spokeSecretLister: fakeSpokeInformerFactory.Core().V1().Secrets().Lister(),
		hubSecretLister:   fakeHubInformerFactory.Core().V1().Secrets().Lister(),
		clusterName:       "test",
		recorder:          eventstesting.NewTestingEventRecorder(t),
	}

}
func TestBlueSecretSync(t *testing.T) {
	cases := []struct {
		name           string
		hubResources   []runtime.Object
		spokeResources []runtime.Object
		errExpected    bool
		syncExpected   bool
	}{
		{
			name:           "no secrets found in the managedcluster",
			spokeResources: []runtime.Object{},
			errExpected:    false,
			syncExpected:   false,
		},
		{
			name: "no valid secrets found in the managedcluster",
			spokeResources: []runtime.Object{
				&corev1.Secret{
					ObjectMeta: metav1.ObjectMeta{
						Name:      "test",
						Namespace: "ns",
					},
					Type: "foobar.io/test",
					Data: map[string][]byte{"namespace": []byte("testdata")},
				},
			},
			errExpected:  false,
			syncExpected: false,
		},
		{
			name: "sync valid secret from managedcluster to the hub",
			spokeResources: []runtime.Object{
				&corev1.Secret{
					ObjectMeta: metav1.ObjectMeta{
						Name:      "test",
						Namespace: "ns",
					},
					Type: "kubernetes.io/rook",
					Data: map[string][]byte{"namespace": []byte("testdata")},
				},
			},
			hubResources: []runtime.Object{
				&corev1.Namespace{
					ObjectMeta: metav1.ObjectMeta{
						Name: "spokeNS",
					},
				},
			},
			errExpected:  false,
			syncExpected: true,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			fakeCtrl := getFakeBlueTokenExchangeController(t, c.hubResources, c.spokeResources)
			err := fakeCtrl.sync(context.TODO(), NewFakeSyncContext(t, "ns/test"))
			if c.errExpected {
				assert.Error(t, err)
				return
			}
			assert.NoError(t, err)

			actualSecret, err := fakeCtrl.hubKubeClient.CoreV1().Secrets("").Get(context.TODO(), "test", metav1.GetOptions{})
			if c.syncExpected {
				assert.NoError(t, err)
				assert.Equal(t, actualSecret.GetLabels()[CreatedByLabelKey], CreatedByLabelValue)
			} else {
				assert.Error(t, err)
			}
		})
	}
}
