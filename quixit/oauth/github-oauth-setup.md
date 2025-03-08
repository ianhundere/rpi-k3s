# GitHub OAuth Setup for Quixit

To ensure the OAuth2 authentication works correctly, please update your GitHub OAuth application settings to match the following:

## GitHub OAuth Application Settings

1. Go to GitHub Developer Settings: https://github.com/settings/developers
2. Select your OAuth application for Quixit
3. Update the following fields:

- **Application name**: Quixit
- **Homepage URL**: `https://quixit.us` (replace with your actual domain)
- **Authorization callback URL**: `https://quixit.us/oauth2/callback` (replace with your actual domain)

## Important Notes

- The callback URL **must** be `/oauth2/callback` (not `/auth/github/callback`)
- Make sure the GitHub Client ID and Secret in your Kubernetes secrets match the ones in GitHub
- If you've made changes to the GitHub OAuth settings, restart the OAuth2 proxy:
  ```bash
  kubectl rollout restart deployment -n quixit oauth2-proxy
  ```

## Troubleshooting

If you still see redirect issues:

1. Check the logs of the OAuth2 proxy:
   ```bash
   kubectl logs -n quixit -l app=oauth2-proxy
   ```

2. Make sure your browser accepts cookies from your domain

3. Try accessing the site in an incognito/private browsing window

4. Clear your browser cookies and cache before trying again

5. If you're still having issues, try these commands to check the OAuth2 proxy configuration:
   ```bash
   # Check the OAuth2 proxy configuration
   kubectl exec -n quixit $(kubectl get pods -n quixit -l app=oauth2-proxy -o jsonpath='{.items[0].metadata.name}') -- cat /etc/oauth2-proxy/oauth2-proxy.cfg

   # Check if the OAuth2 proxy can reach the upstream service
   kubectl exec -n quixit $(kubectl get pods -n quixit -l app=oauth2-proxy -o jsonpath='{.items[0].metadata.name}') -- wget -O- http://quixit.quixit.svc.cluster.local:44301
   ``` 