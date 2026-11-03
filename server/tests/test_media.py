"""Photo transfer uses real HTTP routes, isolated SQL sessions and temporary files."""
import base64
import hashlib

import pytest
from sqlalchemy import select

from app.config import Settings, get_settings
from app.main import app
from app.members import remove_member
from app.models import PhotoBlob, User
from test_review_regressions import client, db, login, push

PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aS1sAAAAASUVORK5CYII=')


@pytest.fixture
def media(client, db, tmp_path):
    settings = Settings(media_directory=tmp_path / 'private', photo_max_bytes=1024)
    app.dependency_overrides[get_settings] = lambda: settings
    push(db, 'owner', 'records', 'record', {'pet_id': 'pet', 'type': 'note',
         'created_by': 'owner', 'created_at': 1, 'recorded_at': 1}, timestamp=10)
    login(db, 'editor')
    yield client, db, settings
    app.dependency_overrides.pop(get_settings, None)


def upload(client, attachment_id='photo', **kwargs):
    return client.put(f'/api/v1/media/photos/{attachment_id}',
        params={'pet_id': 'pet', 'record_id': 'record'}, content=kwargs.pop('content', PNG), **kwargs)


def test_upload_download_retry_and_private_headers(media):
    client, db, settings = media
    response = upload(client)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body['sha256'] == hashlib.sha256(PNG).hexdigest()
    assert body['size_bytes'] == len(PNG)
    assert upload(client).json() == body
    assert len(db.execute(select(PhotoBlob)).scalars().all()) == 1
    # Another authorized device receives exactly the original bytes.
    login(db, 'viewer')
    response = client.get('/api/v1' + body['remote_url'])
    assert response.status_code == 200
    assert response.content == PNG
    assert response.headers['cache-control'] == 'private, no-store'
    assert response.headers['content-type'] == 'image/png'
    assert not list(settings.media_directory.glob('upload-*'))


@pytest.mark.parametrize('user_id', ['viewer', 'outsider'])
def test_read_only_and_unrelated_accounts_cannot_upload(media, user_id):
    client, db, _ = media
    login(db, user_id)
    assert upload(client).status_code == 403


def test_revocation_blocks_download_immediately(media):
    client, db, _ = media
    body = upload(client).json()
    remove_member('pet', 'editor', user=db.get(User, 'owner'), session=db)
    assert client.get('/api/v1' + body['remote_url']).status_code == 403
    assert upload(client).status_code == 403
    login(db, 'outsider')
    assert client.get('/api/v1' + body['remote_url']).status_code == 403


@pytest.mark.parametrize('content,status', [(b'%PDF-1.7 fake', 415), (b'x' * 1025, 413), (b'', 415)])
def test_invalid_and_oversized_uploads_leave_no_partial_files(media, content, status):
    client, db, settings = media
    assert upload(client, content=content).status_code == status
    assert not list(settings.media_directory.iterdir())
    assert not db.execute(select(PhotoBlob)).scalars().all()


def test_photo_url_binding_and_local_paths_never_leave_the_device(media):
    client, db, _ = media
    url = upload(client).json()['remote_url']
    payload = {'pet_id': 'pet', 'record_id': 'record', 'kind': 'photo',
               'remote_url': url, 'local_path': '/device-A/private/photo.png'}
    result = push(db, 'editor', 'attachments', 'photo', payload, timestamp=20)
    assert len(result['applied']) == 1
    from app.changes import latest_change
    assert 'local_path' not in latest_change(db, 'attachments', 'photo').payload
    forged = push(db, 'editor', 'attachments', 'forged', payload, timestamp=21)
    assert forged['rejected'][0]['result'] == 'invalid'
    payload['remote_url'] = 'https://untrusted.example/photo'
    assert push(db, 'editor', 'attachments', 'photo', payload, timestamp=22)['rejected']
    payload['remote_url'] = url
    payload['local_only'] = 1
    assert push(db, 'editor', 'attachments', 'photo', payload, timestamp=23)['rejected']


def test_deleted_photos_and_parent_records_are_unavailable(media):
    client, db, _ = media
    url = upload(client).json()['remote_url']
    push(db, 'editor', 'attachments', 'photo', {'pet_id': 'pet', 'record_id': 'record',
         'kind': 'photo', 'deleted_at': 30}, timestamp=30, op='delete')
    assert client.get('/api/v1' + url).status_code == 404
    assert upload(client).status_code == 409
    push(db, 'editor', 'records', 'record', {'pet_id': 'pet', 'deleted_at': 40}, timestamp=40, op='delete')
    assert upload(client, 'another').status_code == 404


def test_no_bearer_token_and_invalid_id_are_rejected(media):
    client, db, _ = media
    from app.auth import current_user
    app.dependency_overrides.pop(current_user)
    assert upload(client).status_code == 401
    login(db, 'editor')
    assert upload(client, 'bad.id').status_code == 422
